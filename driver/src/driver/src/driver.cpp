// OpenCardboard SteamVR driver - stage 1: a headset whose head pose comes from the phone.
// The phone listens on TCP (default 172.20.10.1:9000, the USB-hotspot address); this driver connects to it.
// Protocol: see PROTOCOL.md in the repository root.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <openvr_driver.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <exception>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "ws2_32.lib")

using namespace vr;

namespace {

const char* kSection = "driver_opencardboard";

// ---------------------------------------------------------------- logging / settings

// File log: %LOCALAPPDATA%\opencardboard-driver.log  (flushed on every line, so it survives crashes)
SRWLOCK g_logLock = SRWLOCK_INIT;
char g_logPath[MAX_PATH] = {0};
bool g_logPathReady = false;
std::atomic<bool> g_initDone{false};

void FileLog(const char* fmt, ...) {
    char msg[900];
    va_list args;
    va_start(args, fmt);
    vsnprintf(msg, sizeof(msg), fmt, args);
    va_end(args);
    SYSTEMTIME t;
    GetLocalTime(&t);
    AcquireSRWLockExclusive(&g_logLock);
    if (!g_logPathReady) {
        char base[MAX_PATH];
        DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", base, MAX_PATH);
        if (n > 0 && n < MAX_PATH) snprintf(g_logPath, MAX_PATH, "%s\\opencardboard-driver.log", base);
        else snprintf(g_logPath, MAX_PATH, "opencardboard-driver.log");
        g_logPathReady = true;
    }
    FILE* f = fopen(g_logPath, "a");
    if (f) {
        fprintf(f, "%02d:%02d:%02d.%03d [pid %lu tid %lu] %s\n", t.wHour, t.wMinute, t.wSecond,
                t.wMilliseconds, GetCurrentProcessId(), GetCurrentThreadId(), msg);
        fflush(f);
        fclose(f);
    }
    ReleaseSRWLockExclusive(&g_logLock);
}

void Log(const char* fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf) - 2, fmt, args);
    va_end(args);
    FileLog("%s", buf);
    if (g_initDone) {
        size_t n = strlen(buf);
        buf[n] = '\n';
        buf[n + 1] = 0;
        if (IVRDriverLog* l = VRDriverLog()) l->Log(buf);
    }
}

// ---- crash diagnostics: record which module is on the stack when something aborts

void LogBacktrace() {
    void* frames[24];
    USHORT n = CaptureStackBackTrace(0, 24, frames, nullptr);
    for (USHORT i = 0; i < n; i++) {
        HMODULE mod = nullptr;
        char name[MAX_PATH] = "?";
        if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               (LPCSTR)frames[i], &mod) && mod) {
            GetModuleFileNameA(mod, name, MAX_PATH);
        }
        const char* base = strrchr(name, '\\');
        base = base ? base + 1 : name;
        FileLog("  frame %u: %s+0x%llX", (unsigned)i, base,
                (unsigned long long)((uintptr_t)frames[i] - (uintptr_t)mod));
    }
}

LPTOP_LEVEL_EXCEPTION_FILTER g_prevFilter = nullptr;
std::terminate_handler g_prevTerminate = nullptr;
void (*g_prevAbort)(int) = nullptr;

LONG WINAPI CrashFilter(EXCEPTION_POINTERS* ep) {
    if (ep && ep->ExceptionRecord) {
        HMODULE mod = nullptr;
        char name[MAX_PATH] = "?";
        if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               (LPCSTR)ep->ExceptionRecord->ExceptionAddress, &mod) && mod) {
            GetModuleFileNameA(mod, name, MAX_PATH);
        }
        FileLog("UNHANDLED EXCEPTION code=0x%08lX at %p in %s",
                ep->ExceptionRecord->ExceptionCode, ep->ExceptionRecord->ExceptionAddress, name);
        LogBacktrace();
    }
    return g_prevFilter ? g_prevFilter(ep) : EXCEPTION_CONTINUE_SEARCH;
}

void TerminateHandler() {
    FileLog("std::terminate called (uncaught exception, or a thread destroyed while running)");
    LogBacktrace();
    if (g_prevTerminate) g_prevTerminate();
    abort();
}

void AbortHandler(int sig) {
    FileLog("SIGABRT: abort() was called");
    LogBacktrace();
    if (g_prevAbort && g_prevAbort != SIG_DFL && g_prevAbort != SIG_IGN) g_prevAbort(sig);
}

void InstallCrashHandlers() {
    static bool done = false;
    if (done) return;
    done = true;
    g_prevFilter = SetUnhandledExceptionFilter(CrashFilter);
    g_prevTerminate = std::set_terminate(TerminateHandler);
    g_prevAbort = signal(SIGABRT, AbortHandler);
}

float SettingF(const char* key, float def) {
    EVRSettingsError e = VRSettingsError_None;
    float v = VRSettings()->GetFloat(kSection, key, &e);
    return e == VRSettingsError_None ? v : def;
}

int32_t SettingI(const char* key, int32_t def) {
    EVRSettingsError e = VRSettingsError_None;
    int32_t v = VRSettings()->GetInt32(kSection, key, &e);
    return e == VRSettingsError_None ? v : def;
}

std::string SettingS(const char* key, const char* def) {
    char buf[256] = {0};
    EVRSettingsError e = VRSettingsError_None;
    VRSettings()->GetString(kSection, key, buf, sizeof(buf), &e);
    return e == VRSettingsError_None ? std::string(buf) : std::string(def);
}

// ---------------------------------------------------------------- protocol bits

constexpr uint32_t kMagic = 0x3143564F;
enum MsgType : uint16_t {
    MSG_HELLO = 1, MSG_STREAM_CONFIG = 2, MSG_POSE = 3, MSG_VIDEO = 4,
    MSG_PING = 5, MSG_PONG = 6, MSG_KEYREQ = 7
};

// Rotation matrix (row r, column c) -> quaternion. Columns are the head's right/up/back axes.
HmdQuaternion_t QuatFromMatrix(const float m[3][3]) {
    HmdQuaternion_t q;
    float tr = m[0][0] + m[1][1] + m[2][2];
    if (tr > 0.0f) {
        float s = std::sqrt(tr + 1.0f) * 2.0f;
        q.w = 0.25f * s;
        q.x = (m[2][1] - m[1][2]) / s;
        q.y = (m[0][2] - m[2][0]) / s;
        q.z = (m[1][0] - m[0][1]) / s;
    } else if (m[0][0] > m[1][1] && m[0][0] > m[2][2]) {
        float s = std::sqrt(1.0f + m[0][0] - m[1][1] - m[2][2]) * 2.0f;
        q.w = (m[2][1] - m[1][2]) / s;
        q.x = 0.25f * s;
        q.y = (m[0][1] + m[1][0]) / s;
        q.z = (m[0][2] + m[2][0]) / s;
    } else if (m[1][1] > m[2][2]) {
        float s = std::sqrt(1.0f + m[1][1] - m[0][0] - m[2][2]) * 2.0f;
        q.w = (m[0][2] - m[2][0]) / s;
        q.x = (m[0][1] + m[1][0]) / s;
        q.y = 0.25f * s;
        q.z = (m[1][2] + m[2][1]) / s;
    } else {
        float s = std::sqrt(1.0f + m[2][2] - m[0][0] - m[1][1]) * 2.0f;
        q.w = (m[1][0] - m[0][1]) / s;
        q.x = (m[0][2] + m[2][0]) / s;
        q.y = (m[1][2] + m[2][1]) / s;
        q.z = 0.25f * s;
    }
    return q;
}

// ---------------------------------------------------------------- the headset

class HmdDevice : public ITrackedDeviceServerDriver, public IVRDisplayComponent {
public:
    HmdDevice() {
        serial_ = SettingS("serialNumber", "OPENCARDBOARD-001");
        model_ = SettingS("modelNumber", "OpenCardboard");
        winX_ = SettingI("windowX", 100);
        winY_ = SettingI("windowY", 100);
        winW_ = SettingI("windowWidth", 1280);
        winH_ = SettingI("windowHeight", 640);
        renderW_ = SettingI("renderWidth", 640);
        renderH_ = SettingI("renderHeight", 640);
        freq_ = SettingF("displayFrequency", 60.0f);
        ipd_ = SettingF("ipd", 0.064f);
        photons_ = SettingF("secondsFromVsyncToPhotons", 0.011f);
        headHeight_ = SettingF("headHeight", 1.6f);
        float fov = SettingF("fovTan", 1.2f);
        for (int e = 0; e < 2; e++)
            for (int i = 0; i < 4; i++) frust_[e][i] = fov;
        q_.w = 1; q_.x = 0; q_.y = 0; q_.z = 0;
    }

    const std::string& Serial() const { return serial_; }

    // ITrackedDeviceServerDriver
    EVRInitError Activate(uint32_t objectId) {
        objectId_ = objectId;
        PropertyContainerHandle_t c = VRProperties()->TrackedDeviceToPropertyContainer(objectId);
        VRProperties()->SetStringProperty(c, Prop_ModelNumber_String, model_.c_str());
        VRProperties()->SetStringProperty(c, Prop_ManufacturerName_String, "OpenCardboard");
        VRProperties()->SetStringProperty(c, Prop_TrackingSystemName_String, "opencardboard");
        VRProperties()->SetStringProperty(c, Prop_RenderModelName_String, "generic_hmd");
        VRProperties()->SetFloatProperty(c, Prop_UserIpdMeters_Float, ipd_);
        VRProperties()->SetFloatProperty(c, Prop_UserHeadToEyeDepthMeters_Float, 0.0f);
        VRProperties()->SetFloatProperty(c, Prop_DisplayFrequency_Float, freq_);
        VRProperties()->SetFloatProperty(c, Prop_SecondsFromVsyncToPhotons_Float, photons_);
        VRProperties()->SetUint64Property(c, Prop_CurrentUniverseId_Uint64, 2);
        Log("OpenCardboard HMD activated (object id %u)", objectId);
        return VRInitError_None;
    }
    void Deactivate() { Log("HMD deactivated"); objectId_ = k_unTrackedDeviceIndexInvalid; }
    void EnterStandby() {}
    void* GetComponent(const char* name) {
        Log("GetComponent(%s)", name ? name : "(null)");
        if (name && _stricmp(name, IVRDisplayComponent_Version) == 0)
            return static_cast<IVRDisplayComponent*>(this);
        return nullptr;
    }
    void DebugRequest(const char*, char* response, uint32_t size) {
        if (size > 0) response[0] = 0;
    }
    DriverPose_t GetPose() { return BuildPose(); }

    // IVRDisplayComponent
    void GetWindowBounds(int32_t* x, int32_t* y, uint32_t* w, uint32_t* h) {
        *x = winX_; *y = winY_; *w = (uint32_t)winW_; *h = (uint32_t)winH_;
    }
    bool IsDisplayOnDesktop() { return true; }
    bool IsDisplayRealDisplay() { return false; }
    void GetRecommendedRenderTargetSize(uint32_t* w, uint32_t* h) {
        *w = (uint32_t)renderW_; *h = (uint32_t)renderH_;
    }
    void GetEyeOutputViewport(EVREye eye, uint32_t* x, uint32_t* y, uint32_t* w, uint32_t* h) {
        *y = 0;
        *w = (uint32_t)renderW_;
        *h = (uint32_t)renderH_;
        *x = (eye == Eye_Left) ? 0 : (uint32_t)renderW_;
    }
    void GetProjectionRaw(EVREye eye, float* left, float* right, float* top, float* bottom) {
        std::lock_guard<std::mutex> g(mu_);
        const float* f = frust_[eye == Eye_Left ? 0 : 1];   // left, right, up, down (positive)
        *left = -f[0];
        *right = f[1];
        *top = -f[2];       // OpenVR raw projection: top is negative, bottom positive
        *bottom = f[3];
    }
    DistortionCoordinates_t ComputeDistortion(EVREye, float u, float v) {
        // The phone applies the lens distortion, so SteamVR renders undistorted images.
        DistortionCoordinates_t d;
        d.rfRed[0] = u;   d.rfRed[1] = v;
        d.rfGreen[0] = u; d.rfGreen[1] = v;
        d.rfBlue[0] = u;  d.rfBlue[1] = v;
        return d;
    }
    bool ComputeInverseDistortion(HmdVector2_t*, EVREye, uint32_t, float, float) { return false; }

    // ---- called from the network thread
    void SetConnected(bool c) {
        { std::lock_guard<std::mutex> g(mu_); connected_ = c; }
        PushPose();
    }
    void OnHello(const float fl[4], const float fr[4]) {
        std::lock_guard<std::mutex> g(mu_);
        for (int i = 0; i < 4; i++) { frust_[0][i] = fl[i]; frust_[1][i] = fr[i]; }
    }
    void OnPose(const float rot[9], const float pos[3]) {
        float m[3][3];
        for (int c = 0; c < 3; c++)
            for (int r = 0; r < 3; r++) m[r][c] = rot[c * 3 + r];   // column-major on the wire
        HmdQuaternion_t q = QuatFromMatrix(m);
        {
            std::lock_guard<std::mutex> g(mu_);
            q_ = q;
            for (int i = 0; i < 3; i++) pos_[i] = pos[i];
        }
        PushPose();
    }
    void PushPose() {
        uint32_t id = objectId_;
        if (id != k_unTrackedDeviceIndexInvalid)
            VRServerDriverHost()->TrackedDevicePoseUpdated(id, BuildPose(), sizeof(DriverPose_t));
    }

private:
    DriverPose_t BuildPose() {
        DriverPose_t p = {};
        std::lock_guard<std::mutex> g(mu_);
        p.qWorldFromDriverRotation.w = 1; p.qWorldFromDriverRotation.x = 0;
        p.qWorldFromDriverRotation.y = 0; p.qWorldFromDriverRotation.z = 0;
        p.qDriverFromHeadRotation.w = 1;  p.qDriverFromHeadRotation.x = 0;
        p.qDriverFromHeadRotation.y = 0;  p.qDriverFromHeadRotation.z = 0;
        p.qRotation = q_;
        p.vecPosition[0] = pos_[0];
        p.vecPosition[1] = headHeight_ + pos_[1];
        p.vecPosition[2] = pos_[2];
        p.poseIsValid = connected_;
        p.deviceIsConnected = connected_;
        p.result = connected_ ? TrackingResult_Running_OK : TrackingResult_Uninitialized;
        p.shouldApplyHeadModel = false;
        p.willDriftInYaw = true;
        return p;
    }

    std::string serial_, model_;
    int32_t winX_, winY_, winW_, winH_, renderW_, renderH_;
    float freq_, ipd_, photons_, headHeight_;
    float frust_[2][4];
    std::atomic<uint32_t> objectId_{k_unTrackedDeviceIndexInvalid};
    std::mutex mu_;
    bool connected_ = false;
    HmdQuaternion_t q_;
    float pos_[3] = {0, 0, 0};
};

// ---------------------------------------------------------------- network client

class NetClient {
public:
    void Start(const std::string& host, uint16_t port, HmdDevice* hmd) {
        host_ = host; port_ = port; hmd_ = hmd; stop_ = false;
        thread_ = std::thread([this] {
            FileLog("network thread started");
            try {
                Run();
            } catch (const std::exception& e) {
                FileLog("network thread: exception: %s", e.what());
            } catch (...) {
                FileLog("network thread: unknown exception");
            }
            FileLog("network thread ended");
        });
    }
    void Stop() {
        stop_ = true;
        SOCKET s = sock_;
        if (s != INVALID_SOCKET) { shutdown(s, SD_BOTH); closesocket(s); }
        if (thread_.joinable()) thread_.join();
    }

private:
    void SleepMs(int ms) {
        for (int i = 0; i < ms / 50 && !stop_; i++) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    SOCKET Connect() {
        SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return s;
        sockaddr_in a = {};
        a.sin_family = AF_INET;
        a.sin_port = htons(port_);
        if (inet_pton(AF_INET, host_.c_str(), &a.sin_addr) != 1) { closesocket(s); return INVALID_SOCKET; }
        u_long nb = 1;
        ioctlsocket(s, FIONBIO, &nb);
        int r = connect(s, (sockaddr*)&a, sizeof(a));
        if (r == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK) { closesocket(s); return INVALID_SOCKET; }
        fd_set wf, ef;
        FD_ZERO(&wf); FD_ZERO(&ef);
        FD_SET(s, &wf); FD_SET(s, &ef);
        timeval tv = {1, 0};
        r = select(0, nullptr, &wf, &ef, &tv);
        if (r <= 0 || !FD_ISSET(s, &wf)) { closesocket(s); return INVALID_SOCKET; }
        nb = 0;
        ioctlsocket(s, FIONBIO, &nb);
        int one = 1;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char*)&one, sizeof(one));
        DWORD to = 3000;
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof(to));
        return s;
    }

    static bool RecvAll(SOCKET s, uint8_t* buf, int n) {
        int got = 0;
        while (got < n) {
            int r = recv(s, (char*)buf + got, n - got, 0);
            if (r <= 0) return false;
            got += r;
        }
        return true;
    }

    bool SendMsg(SOCKET s, uint16_t type, const uint8_t* payload, uint32_t len) {
        uint8_t hdr[12];
        uint16_t zero = 0;
        memcpy(hdr, &kMagic, 4);
        memcpy(hdr + 4, &type, 2);
        memcpy(hdr + 6, &zero, 2);
        memcpy(hdr + 8, &len, 4);
        std::lock_guard<std::mutex> g(sendMu_);
        if (send(s, (const char*)hdr, 12, 0) != 12) return false;
        if (len && send(s, (const char*)payload, (int)len, 0) != (int)len) return false;
        return true;
    }

    void Session(SOCKET s) {
        std::vector<uint8_t> payload;
        auto lastReport = std::chrono::steady_clock::now();
        int poses = 0;
        while (!stop_) {
            uint8_t hdr[12];
            if (!RecvAll(s, hdr, 12)) { Log("phone link: receive failed or timed out"); return; }
            uint32_t magic, len; uint16_t type;
            memcpy(&magic, hdr, 4); memcpy(&type, hdr + 4, 2); memcpy(&len, hdr + 8, 4);
            if (magic != kMagic || len > (4u << 20)) { Log("phone link: bad header"); return; }
            payload.resize(len);
            if (len && !RecvAll(s, payload.data(), (int)len)) { Log("phone link: payload receive failed"); return; }

            if (type == MSG_HELLO && len >= 60) {
                float fl[4], fr[4];
                memcpy(fl, payload.data() + 28, 16);
                memcpy(fr, payload.data() + 44, 16);
                hmd_->OnHello(fl, fr);
                Log("phone hello: left eye frustum l=%.2f r=%.2f u=%.2f d=%.2f", fl[0], fl[1], fl[2], fl[3]);
            } else if (type == MSG_POSE && len >= 64) {
                float rot[9], pos[3];
                memcpy(rot, payload.data() + 16, 36);
                memcpy(pos, payload.data() + 52, 12);
                hmd_->OnPose(rot, pos);
                poses++;
            } else if (type == MSG_PING) {
                if (!SendMsg(s, MSG_PONG, payload.data(), len)) return;
            }

            auto now = std::chrono::steady_clock::now();
            if (now - lastReport > std::chrono::seconds(10)) {
                Log("phone link: %d poses in the last 10 s", poses);
                poses = 0;
                lastReport = now;
            }
        }
    }

    void Run() {
        WSADATA w;
        WSAStartup(MAKEWORD(2, 2), &w);
        Log("looking for the phone at %s:%u", host_.c_str(), (unsigned)port_);
        while (!stop_) {
            SOCKET s = Connect();
            if (s == INVALID_SOCKET) { SleepMs(1000); continue; }
            sock_ = s;
            Log("connected to the phone");
            hmd_->SetConnected(true);
            Session(s);
            sock_ = INVALID_SOCKET;
            closesocket(s);
            hmd_->SetConnected(false);
            Log("disconnected from the phone");
            SleepMs(500);
        }
        WSACleanup();
    }

    std::string host_;
    uint16_t port_ = 9000;
    HmdDevice* hmd_ = nullptr;
    std::atomic<bool> stop_{false};
    std::atomic<SOCKET> sock_{INVALID_SOCKET};
    std::mutex sendMu_;
    std::thread thread_;
};

// ---------------------------------------------------------------- driver entry points

class Provider : public IServerTrackedDeviceProvider {
public:
    EVRInitError Init(IVRDriverContext* ctx) {
        FileLog("Provider::Init begin");
        VR_INIT_SERVER_DRIVER_CONTEXT(ctx);
        g_initDone = true;
        Log("driver context ready");
        hmd_ = new HmdDevice();
        Log("HMD object created");
        bool added = VRServerDriverHost()->TrackedDeviceAdded(hmd_->Serial().c_str(), TrackedDeviceClass_HMD, hmd_);
        Log("TrackedDeviceAdded returned %d", added ? 1 : 0);
        std::string host = SettingS("phoneAddress", "172.20.10.1");
        int port = SettingI("phonePort", 9000);
        net_.Start(host, (uint16_t)port, hmd_);
        Log("Provider::Init done");
        return VRInitError_None;
    }
    void Cleanup() {
        Log("Provider::Cleanup begin");
        net_.Stop();
        hmd_ = nullptr;     // intentionally not deleted: SteamVR may still hold the pointer
        Log("Provider::Cleanup done");
    }
    const char* const* GetInterfaceVersions() { return k_InterfaceVersions; }
    void RunFrame() {
        VREvent_t ev;
        while (VRServerDriverHost()->PollNextEvent(&ev, sizeof(ev))) {}
        if (hmd_) hmd_->PushPose();
    }
    bool ShouldBlockStandbyMode() { return false; }
    void EnterStandby() {}
    void LeaveStandby() {}

private:
    HmdDevice* hmd_ = nullptr;
    NetClient net_;
};

class Watchdog : public IVRWatchdogProvider {
public:
    EVRInitError Init(IVRDriverContext* ctx) {
        VR_INIT_WATCHDOG_DRIVER_CONTEXT(ctx);
        return VRInitError_None;
    }
    void Cleanup() {}
};

// Heap-allocated and never destroyed, so nothing runs during process/DLL teardown.
Provider* g_provider = nullptr;
Watchdog* g_watchdog = nullptr;

}  // namespace

extern "C" __declspec(dllexport) void* HmdDriverFactory(const char* name, int* returnCode) {
    InstallCrashHandlers();
    char exe[MAX_PATH] = "?";
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    FileLog("HmdDriverFactory(\"%s\") called inside %s", name ? name : "(null)", exe);
    if (name && strcmp(name, IServerTrackedDeviceProvider_Version) == 0) {
        if (!g_provider) g_provider = new Provider();
        return g_provider;
    }
    if (name && strcmp(name, IVRWatchdogProvider_Version) == 0) {
        if (!g_watchdog) g_watchdog = new Watchdog();
        return g_watchdog;
    }
    FileLog("HmdDriverFactory: unknown interface");
    if (returnCode) *returnCode = VRInitError_Init_InterfaceNotFound;
    return nullptr;
}
