// OpenCardboard SteamVR driver - stage 1: a headset whose head pose comes from the phone.
// The phone listens on TCP (default 172.20.10.1:9000, the USB-hotspot address); this driver connects to it.
// Protocol: see PROTOCOL.md in the repository root.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
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
#include <algorithm>
#include <map>
#include <d3d11.h>
#include <xinput.h>
#include <d3d11_4.h>
#include <d3dcompiler.h>
#include <condition_variable>
#include <deque>
#include <functional>
#include <dxgi.h>
#include <wrl/client.h>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "xinput.lib")

using namespace vr;
using Microsoft::WRL::ComPtr;

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

bool SettingB(const char* key, bool def) {
    EVRSettingsError e = VRSettingsError_None;
    bool v = VRSettings()->GetBool(kSection, key, &e);
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

// ---------------------------------------------------------------- video: side-by-side + ffmpeg/NVENC
// First-light version: the GPU composes both eyes into one frame, the frame is read back to the CPU and
// piped to ffmpeg (h264_nvenc), and ffmpeg's output is split into access units and sent to the phone.
// Later this can be replaced with a direct NVENC path for lower latency.

const char* kHlsl = R"HLSL(
cbuffer CB : register(b0) { float4 bounds; };
struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };
VSOut VS(uint id : SV_VertexID) {
    VSOut o;
    float2 p = float2((id << 1) & 2, id & 2);
    o.pos = float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
    o.uv = p;
    return o;
}
Texture2D tex : register(t0);
SamplerState smp : register(s0);
float4 PS(VSOut i) : SV_TARGET {
    float2 uv = float2(lerp(bounds.x, bounds.z, i.uv.x), lerp(bounds.y, bounds.w, i.uv.y));
    return tex.Sample(smp, uv);
}
)HLSL";

std::string FindFfmpeg(const std::string& setting) {
    if (!setting.empty() && setting != "auto") return setting;
    char base[MAX_PATH];
    DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", base, MAX_PATH);
    if (n > 0 && n < MAX_PATH) {
        std::string pk = std::string(base) + "\\Microsoft\\WinGet\\Packages\\";
        WIN32_FIND_DATAA fd;
        HANDLE h = FindFirstFileA((pk + "Gyan.FFmpeg*").c_str(), &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
                std::string d1 = pk + fd.cFileName + "\\";
                WIN32_FIND_DATAA f2;
                HANDLE h2 = FindFirstFileA((d1 + "ffmpeg-*").c_str(), &f2);
                if (h2 != INVALID_HANDLE_VALUE) {
                    do {
                        std::string exe = d1 + f2.cFileName + "\\bin\\ffmpeg.exe";
                        if (GetFileAttributesA(exe.c_str()) != INVALID_FILE_ATTRIBUTES) {
                            FindClose(h2); FindClose(h);
                            return exe;
                        }
                    } while (FindNextFileA(h2, &f2));
                    FindClose(h2);
                }
            } while (FindNextFileA(h, &fd));
            FindClose(h);
        }
    }
    return "ffmpeg";
}

bool HasIdr(const uint8_t* d, size_t n) {
    for (size_t i = 0; i + 3 < n; i++) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 && (d[i + 3] & 0x1F) == 5) return true;
    }
    return false;
}

class Streamer {
public:
    using AUCallback = std::function<void(const float* rot, const float* pos, bool key,
                                          const uint8_t* data, size_t len)>;

    bool Ready() const { return ready_; }

    bool Start(ID3D11Device* dev, ID3D11DeviceContext* ctx, int eyeW, int eyeH, int fps, int mbps,
               const std::string& ffmpegSetting, const std::string& preset, AUCallback cb) {
        std::lock_guard<std::mutex> life(lifeMu_);
        StopLocked();
        dev_ = dev; ctx_ = ctx; eyeW_ = eyeW; eyeH_ = eyeH; cb_ = cb;
        ComPtr<ID3D11Multithread> mt;
        if (SUCCEEDED(ctx_.As(&mt))) mt->SetMultithreadProtected(TRUE);

        ComPtr<ID3DBlob> vsb, psb, err;
        HRESULT hr = D3DCompile(kHlsl, strlen(kHlsl), "oc", nullptr, nullptr, "VS", "vs_4_0", 0, 0, &vsb, &err);
        if (FAILED(hr)) { Log("HLSL VS compile failed: %s", err ? (const char*)err->GetBufferPointer() : "?"); return false; }
        hr = D3DCompile(kHlsl, strlen(kHlsl), "oc", nullptr, nullptr, "PS", "ps_4_0", 0, 0, &psb, &err);
        if (FAILED(hr)) { Log("HLSL PS compile failed: %s", err ? (const char*)err->GetBufferPointer() : "?"); return false; }
        if (FAILED(dev_->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &vs_))) return false;
        if (FAILED(dev_->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &ps_))) return false;

        D3D11_BUFFER_DESC bd = {};
        bd.ByteWidth = 16;
        bd.Usage = D3D11_USAGE_DEFAULT;
        bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        if (FAILED(dev_->CreateBuffer(&bd, nullptr, &cb_buf_))) return false;

        D3D11_SAMPLER_DESC sd = {};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        if (FAILED(dev_->CreateSamplerState(&sd, &smp_))) return false;

        D3D11_RASTERIZER_DESC rd = {};
        rd.FillMode = D3D11_FILL_SOLID;
        rd.CullMode = D3D11_CULL_NONE;
        rd.DepthClipEnable = TRUE;
        if (FAILED(dev_->CreateRasterizerState(&rd, &rs_))) return false;

        D3D11_TEXTURE2D_DESC td = {};
        td.Width = (UINT)(eyeW * 2);
        td.Height = (UINT)eyeH;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET;
        if (FAILED(dev_->CreateTexture2D(&td, nullptr, &out_))) return false;
        if (FAILED(dev_->CreateRenderTargetView(out_.Get(), nullptr, &rtv_))) return false;

        D3D11_TEXTURE2D_DESC sg = td;
        sg.Usage = D3D11_USAGE_STAGING;
        sg.BindFlags = 0;
        sg.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        for (int i = 0; i < kRing; i++)
            if (FAILED(dev_->CreateTexture2D(&sg, nullptr, &stage_[i]))) return false;

        if (!LaunchFfmpeg(FindFfmpeg(ffmpegSetting), eyeW * 2, eyeH, fps, mbps, preset)) return false;

        stop_ = false;
        writeIdx_ = 0;
        inflight_ = 0;
        q_.clear();
        poses_.clear();
        running_ = true;
        writer_ = std::thread([this] { WriterLoop(); });
        reader_ = std::thread([this] { ReaderLoop(); });
        ready_ = true;
        Log("streamer started: %dx%d per eye, %d fps, %d Mbps", eyeW, eyeH, fps, mbps);
        return true;
    }

    void Stop() {
        std::lock_guard<std::mutex> life(lifeMu_);
        StopLocked();
    }

    void ForgetTextures() { srvCache_.clear(); }

    // called from Present() while the compositor's sync mutex is held
    void SubmitFrame(ID3D11Texture2D* left, const VRTextureBounds_t& bl,
                     ID3D11Texture2D* right, const VRTextureBounds_t& br,
                     const float rot[9], const float pos[3]) {
        std::unique_lock<std::mutex> life(lifeMu_, std::try_to_lock);
        if (!life.owns_lock() || !ready_) return;
        int slot;
        {
            std::lock_guard<std::mutex> g(qmu_);
            if (inflight_ >= kRing) { dropped_++; return; }
            slot = writeIdx_;
            writeIdx_ = (writeIdx_ + 1) % kRing;
            inflight_++;
        }
        ComPtr<ID3D11ShaderResourceView> sl = Srv(left), sr = Srv(right);
        if (!sl || !sr) {
            std::lock_guard<std::mutex> g(qmu_);
            inflight_--;
            writeIdx_ = (writeIdx_ + kRing - 1) % kRing;
            return;
        }

        ctx_->OMSetRenderTargets(1, rtv_.GetAddressOf(), nullptr);
        ctx_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx_->IASetInputLayout(nullptr);
        ctx_->VSSetShader(vs_.Get(), nullptr, 0);
        ctx_->PSSetShader(ps_.Get(), nullptr, 0);
        ctx_->PSSetSamplers(0, 1, smp_.GetAddressOf());
        ctx_->PSSetConstantBuffers(0, 1, cb_buf_.GetAddressOf());
        ctx_->RSSetState(rs_.Get());
        for (int e = 0; e < 2; e++) {
            D3D11_VIEWPORT vp = {(float)(e * eyeW_), 0.0f, (float)eyeW_, (float)eyeH_, 0.0f, 1.0f};
            ctx_->RSSetViewports(1, &vp);
            const VRTextureBounds_t& b = (e == 0) ? bl : br;
            float cbv[4] = {b.uMin, b.vMin, b.uMax, b.vMax};
            ctx_->UpdateSubresource(cb_buf_.Get(), 0, nullptr, cbv, 0, 0);
            ID3D11ShaderResourceView* srv = (e == 0) ? sl.Get() : sr.Get();
            ctx_->PSSetShaderResources(0, 1, &srv);
            ctx_->Draw(3, 0);
        }
        ID3D11ShaderResourceView* nullSrv = nullptr;
        ctx_->PSSetShaderResources(0, 1, &nullSrv);
        ID3D11RenderTargetView* nullRtv = nullptr;
        ctx_->OMSetRenderTargets(1, &nullRtv, nullptr);
        ctx_->CopyResource(stage_[slot].Get(), out_.Get());
        ctx_->Flush();

        Item it;
        it.slot = slot;
        memcpy(it.rot, rot, sizeof(it.rot));
        memcpy(it.pos, pos, sizeof(it.pos));
        {
            std::lock_guard<std::mutex> g(qmu_);
            q_.push_back(it);
        }
        cv_.notify_one();
    }

private:
    static constexpr int kRing = 3;
    struct Item { int slot = 0; float rot[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1}; float pos[3] = {0, 0, 0}; };

    ComPtr<ID3D11ShaderResourceView> Srv(ID3D11Texture2D* t) {
        auto it = srvCache_.find(t);
        if (it != srvCache_.end()) return it->second;
        ComPtr<ID3D11ShaderResourceView> v;
        if (FAILED(dev_->CreateShaderResourceView(t, nullptr, &v))) Log("CreateShaderResourceView failed");
        srvCache_[t] = v;
        return v;
    }

    bool LaunchFfmpeg(const std::string& exe, int w, int h, int fps, int mbps, const std::string& preset) {
        char logDir[MAX_PATH];
        DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", logDir, MAX_PATH);
        std::string logPath = (n > 0 && n < MAX_PATH) ? std::string(logDir) + "\\opencardboard-ffmpeg.log"
                                                      : std::string("opencardboard-ffmpeg.log");
        SECURITY_ATTRIBUTES sa = {sizeof(sa), nullptr, TRUE};
        HANDLE inR = nullptr, inW = nullptr, outR = nullptr, outW = nullptr;
        if (!CreatePipe(&inR, &inW, &sa, 16u << 20)) return false;
        if (!CreatePipe(&outR, &outW, &sa, 4u << 20)) return false;
        SetHandleInformation(inW, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(outR, HANDLE_FLAG_INHERIT, 0);
        HANDLE errF = CreateFileA(logPath.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

        char cmd[2048];
        snprintf(cmd, sizeof(cmd),
                 "\"%s\" -hide_banner -loglevel warning -f rawvideo -pix_fmt rgb0 -s %dx%d -r %d -i - -an "
                 "-c:v h264_nvenc -preset %s -tune ll -rc cbr -b:v %dM -maxrate %dM -bufsize %dM "
                 "-g %d -bf 0 -zerolatency 1 -delay 0 -forced-idr 1 -aud 1 "
                 "-bsf:v dump_extra=freq=keyframe -f h264 -",
                 exe.c_str(), w, h, fps, preset.c_str(), mbps, mbps, std::max(1, mbps / std::max(fps, 1) + 1), fps);
        Log("launching: %s", cmd);

        STARTUPINFOA si = {};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = inR;
        si.hStdOutput = outW;
        si.hStdError = (errF != INVALID_HANDLE_VALUE) ? errF : GetStdHandle(STD_ERROR_HANDLE);
        PROCESS_INFORMATION pi = {};
        BOOL ok = CreateProcessA(nullptr, cmd, nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
        DWORD lastErr = GetLastError();
        CloseHandle(inR);
        CloseHandle(outW);
        if (errF != INVALID_HANDLE_VALUE) CloseHandle(errF);
        if (!ok) {
            Log("could not start ffmpeg (error %lu). Set ffmpegPath in default.vrsettings.", (unsigned long)lastErr);
            CloseHandle(inW);
            CloseHandle(outR);
            return false;
        }
        CloseHandle(pi.hThread);
        proc_ = pi.hProcess;
        hIn_ = inW;
        hOut_ = outR;
        return true;
    }

    static bool WriteAll(HANDLE h, const uint8_t* d, size_t n) {
        size_t off = 0;
        while (off < n) {
            DWORD wrote = 0;
            DWORD chunk = (DWORD)std::min<size_t>(n - off, 1u << 20);
            if (!WriteFile(h, d + off, chunk, &wrote, nullptr) || wrote == 0) return false;
            off += wrote;
        }
        return true;
    }

    void WriterLoop() {
        const size_t W = (size_t)eyeW_ * 2, H = (size_t)eyeH_;
        std::vector<uint8_t> frame(W * H * 4);
        while (true) {
            Item it;
            {
                std::unique_lock<std::mutex> lk(qmu_);
                cv_.wait(lk, [&] { return stop_ || !q_.empty(); });
                if (stop_) break;
                it = q_.front();
                q_.pop_front();
            }
            bool wrote = false;
            D3D11_MAPPED_SUBRESOURCE m;
            if (SUCCEEDED(ctx_->Map(stage_[it.slot].Get(), 0, D3D11_MAP_READ, 0, &m))) {
                for (size_t y = 0; y < H; y++)
                    memcpy(frame.data() + y * W * 4, (const uint8_t*)m.pData + y * m.RowPitch, W * 4);
                ctx_->Unmap(stage_[it.slot].Get(), 0);
                {
                    std::lock_guard<std::mutex> g(poseMu_);
                    poses_.push_back(it);
                }
                wrote = true;
            }
            {
                std::lock_guard<std::mutex> g(qmu_);
                inflight_--;
            }
            if (wrote && !WriteAll(hIn_, frame.data(), frame.size())) {
                if (!stop_) Log("ffmpeg input pipe closed - see opencardboard-ffmpeg.log");
                ready_ = false;
                break;
            }
        }
    }

    void ReaderLoop() {
        std::vector<uint8_t> buf;
        std::vector<uint8_t> chunk(1 << 16);
        uint64_t sent = 0;
        while (true) {
            DWORD n = 0;
            if (!ReadFile(hOut_, chunk.data(), (DWORD)chunk.size(), &n, nullptr) || n == 0) break;
            buf.insert(buf.end(), chunk.begin(), chunk.begin() + n);

            std::vector<size_t> starts;
            for (size_t i = 0; i + 3 < buf.size(); i++) {
                if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1 && buf[i + 3] == 9)
                    starts.push_back((i > 0 && buf[i - 1] == 0) ? i - 1 : i);
            }
            if (starts.size() < 2) continue;
            for (size_t k = 0; k + 1 < starts.size(); k++) {
                const uint8_t* au = buf.data() + starts[k];
                size_t len = starts[k + 1] - starts[k];
                Item pose;
                {
                    std::lock_guard<std::mutex> g(poseMu_);
                    if (!poses_.empty()) { pose = poses_.front(); poses_.pop_front(); }
                }
                if (cb_) cb_(pose.rot, pose.pos, HasIdr(au, len), au, len);
                sent++;
                if (sent == 1 || sent % 600 == 0) Log("streamer: %llu frames sent to the phone", (unsigned long long)sent);
            }
            buf.erase(buf.begin(), buf.begin() + starts.back());
        }
    }

    void StopLocked() {
        if (!running_) return;
        ready_ = false;
        {
            std::lock_guard<std::mutex> g(qmu_);
            stop_ = true;
        }
        cv_.notify_all();
        if (proc_) TerminateProcess(proc_, 0);
        if (writer_.joinable()) writer_.join();
        if (reader_.joinable()) reader_.join();
        if (hIn_) { CloseHandle(hIn_); hIn_ = nullptr; }
        if (hOut_) { CloseHandle(hOut_); hOut_ = nullptr; }
        if (proc_) { CloseHandle(proc_); proc_ = nullptr; }
        srvCache_.clear();
        for (int i = 0; i < kRing; i++) stage_[i].Reset();
        out_.Reset();
        rtv_.Reset();
        running_ = false;
        Log("streamer stopped");
    }

    ComPtr<ID3D11Device> dev_;
    ComPtr<ID3D11DeviceContext> ctx_;
    ComPtr<ID3D11VertexShader> vs_;
    ComPtr<ID3D11PixelShader> ps_;
    ComPtr<ID3D11Buffer> cb_buf_;
    ComPtr<ID3D11SamplerState> smp_;
    ComPtr<ID3D11RasterizerState> rs_;
    ComPtr<ID3D11Texture2D> out_;
    ComPtr<ID3D11RenderTargetView> rtv_;
    ComPtr<ID3D11Texture2D> stage_[kRing];
    std::map<ID3D11Texture2D*, ComPtr<ID3D11ShaderResourceView>> srvCache_;
    int eyeW_ = 0, eyeH_ = 0;
    AUCallback cb_;

    HANDLE proc_ = nullptr, hIn_ = nullptr, hOut_ = nullptr;
    std::thread writer_, reader_;
    std::mutex lifeMu_, qmu_, poseMu_;
    std::condition_variable cv_;
    std::deque<Item> q_;
    std::deque<Item> poses_;
    int writeIdx_ = 0, inflight_ = 0;
    uint64_t dropped_ = 0;
    bool stop_ = false;
    bool running_ = false;
    std::atomic<bool> ready_{false};
};

HmdQuaternion_t QMul(const HmdQuaternion_t& a, const HmdQuaternion_t& b) {
    HmdQuaternion_t r;
    r.w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
    r.x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y;
    r.y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x;
    r.z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w;
    return r;
}
HmdQuaternion_t QConj(const HmdQuaternion_t& a) {
    HmdQuaternion_t r;
    r.w = a.w; r.x = -a.x; r.y = -a.y; r.z = -a.z;
    return r;
}

// ---------------------------------------------------------------- gamepad bridge: a gaze-pointing virtual controller
// SteamVR's menus are operated with a laser pointer + trigger. This device sits in front of the headset,
// pointing where you look, and takes its buttons from an Xbox-style controller connected to the PC:
//   A or right trigger = trigger click      Back  = SteamVR button (opens/closes the dashboard)
//   Start = application menu                Right bumper = grip

void RotateVec(const HmdQuaternion_t& q, double x, double y, double z, double out[3]) {
    // v' = v + 2w(q x v) + 2 q x (q x v)
    double tx = 2.0 * (q.y * z - q.z * y);
    double ty = 2.0 * (q.z * x - q.x * z);
    double tz = 2.0 * (q.x * y - q.y * x);
    out[0] = x + q.w * tx + (q.y * tz - q.z * ty);
    out[1] = y + q.w * ty + (q.z * tx - q.x * tz);
    out[2] = z + q.w * tz + (q.x * ty - q.y * tx);
}

class PadDevice : public ITrackedDeviceServerDriver {
public:
    PadDevice() {
        q_.w = 1; q_.x = 0; q_.y = 0; q_.z = 0;
    }
    const char* Serial() const { return "OPENCARDBOARD-PAD-001"; }

    EVRInitError Activate(uint32_t id) {
        id_ = id;
        PropertyContainerHandle_t c = VRProperties()->TrackedDeviceToPropertyContainer(id);
        VRProperties()->SetStringProperty(c, Prop_ModelNumber_String, "OpenCardboard Gaze Pointer");
        VRProperties()->SetStringProperty(c, Prop_ManufacturerName_String, "OpenCardboard");
        VRProperties()->SetStringProperty(c, Prop_TrackingSystemName_String, "opencardboard");
        VRProperties()->SetStringProperty(c, Prop_ControllerType_String, "vive_controller");
        VRProperties()->SetStringProperty(c, Prop_InputProfilePath_String,
                                          "{htc}/input/vive_controller_profile.json");
        std::string padModel = SettingS("padModel", "hidden");
        if (padModel == "default")
            VRProperties()->SetStringProperty(c, Prop_RenderModelName_String, "vr_controller_vive_1_5");
        else if (padModel == "hidden")
            VRProperties()->SetStringProperty(c, Prop_RenderModelName_String, "opencardboard_no_model");
        // "unset": leave the render model property out
        Log("gaze pointer model mode: %s", padModel.c_str());
        VRProperties()->SetInt32Property(c, Prop_ControllerRoleHint_Int32, TrackedControllerRole_RightHand);
        EVRInputError e1 = VRDriverInput()->CreateBooleanComponent(c, "/input/trigger/click", &hTrigClick_);
        EVRInputError e2 = VRDriverInput()->CreateScalarComponent(c, "/input/trigger/value", &hTrigVal_,
                                                                  VRScalarType_Absolute, VRScalarUnits_NormalizedOneSided);
        EVRInputError e3 = VRDriverInput()->CreateBooleanComponent(c, "/input/system/click", &hSystem_);
        EVRInputError e4 = VRDriverInput()->CreateBooleanComponent(c, "/input/application_menu/click", &hMenu_);
        EVRInputError e5 = VRDriverInput()->CreateBooleanComponent(c, "/input/grip/click", &hGrip_);
        Log("gaze pointer activated (object id %u); component results %d %d %d %d %d", id,
            (int)e1, (int)e2, (int)e3, (int)e4, (int)e5);
        if (!poll_.joinable()) {
            stop_ = false;
            poll_ = std::thread([this] { PollLoop(); });
        }
        return VRInitError_None;
    }
    void Deactivate() { id_ = k_unTrackedDeviceIndexInvalid; }
    void EnterStandby() {}
    void* GetComponent(const char*) { return nullptr; }
    void DebugRequest(const char*, char* response, uint32_t size) { if (size > 0) response[0] = 0; }
    DriverPose_t GetPose() { return BuildPose(); }

    void Shutdown() {
        stop_ = true;
        if (poll_.joinable()) poll_.join();
    }

    void SetHmdPose(const HmdQuaternion_t& q, const double pos[3], bool connected) {
        {
            std::lock_guard<std::mutex> g(mu_);
            q_ = q;
            for (int i = 0; i < 3; i++) pos_[i] = pos[i];
            connected_ = connected;
        }
        uint32_t id = id_;
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
        double off[3];
        RotateVec(q_, 0.0, -0.12, -0.25, off);     // a little below and in front of the eyes
        for (int i = 0; i < 3; i++) p.vecPosition[i] = pos_[i] + off[i];
        p.poseIsValid = connected_;
        p.deviceIsConnected = connected_;
        p.result = connected_ ? TrackingResult_Running_OK : TrackingResult_Uninitialized;
        return p;
    }

    void PollLoop() {
        bool lTrig = false, lSys = false, lMenu = false, lGrip = false;
        float lVal = -1.0f;
        DWORD lSlots = 0xFFFFFFFFu;
        WORD lButtons = 0;
        BYTE lRt = 0;
        while (!stop_) {
            WORD b = 0;
            BYTE rt = 0;
            DWORD slots = 0;
            for (DWORD i = 0; i < 4; i++) {
                XINPUT_STATE st;
                ZeroMemory(&st, sizeof(st));
                if (XInputGetState(i, &st) == ERROR_SUCCESS) {
                    slots |= (1u << i);
                    b |= st.Gamepad.wButtons;
                    if (st.Gamepad.bRightTrigger > rt) rt = st.Gamepad.bRightTrigger;
                }
            }
            if (slots != lSlots) {
                lSlots = slots;
                Log("pad: XInput controller slots connected: 0x%lX (0 = none visible to SteamVR)", (unsigned long)slots);
            }
            if (b != lButtons || (rt > 100) != (lRt > 100)) {
                lButtons = b;
                lRt = rt;
                Log("pad: XInput buttons 0x%04X, right trigger %u", (unsigned)b, (unsigned)rt);
            }

            float val = rt / 255.0f;
            bool trig = (b & XINPUT_GAMEPAD_A) || val > 0.5f;
            bool sys = (b & XINPUT_GAMEPAD_BACK) != 0;
            bool menu = (b & XINPUT_GAMEPAD_START) != 0;
            bool grip = (b & XINPUT_GAMEPAD_RIGHT_SHOULDER) != 0;
            if (trig && val < 0.5f) val = 1.0f;

            if (id_ != k_unTrackedDeviceIndexInvalid) {
                if (trig != lTrig) { VRDriverInput()->UpdateBooleanComponent(hTrigClick_, trig, 0.0); lTrig = trig; Log("pad: trigger %s", trig ? "down" : "up"); }
                if (val != lVal)   { VRDriverInput()->UpdateScalarComponent(hTrigVal_, val, 0.0); lVal = val; }
                if (sys != lSys)   { VRDriverInput()->UpdateBooleanComponent(hSystem_, sys, 0.0); lSys = sys; Log("pad: system button %s", sys ? "down" : "up"); }
                if (menu != lMenu) { VRDriverInput()->UpdateBooleanComponent(hMenu_, menu, 0.0); lMenu = menu; }
                if (grip != lGrip) { VRDriverInput()->UpdateBooleanComponent(hGrip_, grip, 0.0); lGrip = grip; }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(8));
        }
    }

    std::atomic<uint32_t> id_{k_unTrackedDeviceIndexInvalid};
    VRInputComponentHandle_t hTrigClick_ = k_ulInvalidInputComponentHandle;
    VRInputComponentHandle_t hTrigVal_ = k_ulInvalidInputComponentHandle;
    VRInputComponentHandle_t hSystem_ = k_ulInvalidInputComponentHandle;
    VRInputComponentHandle_t hMenu_ = k_ulInvalidInputComponentHandle;
    VRInputComponentHandle_t hGrip_ = k_ulInvalidInputComponentHandle;
    std::mutex mu_;
    HmdQuaternion_t q_;
    double pos_[3] = {0, 1.6, 0};
    bool connected_ = false;
    std::thread poll_;
    std::atomic<bool> stop_{false};
};

// ---------------------------------------------------------------- the headset

class HmdDevice : public ITrackedDeviceServerDriver, public IVRDisplayComponent,
                  public IVRDriverDirectModeComponent {
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
        photons_ = SettingF("secondsFromVsyncToPhotons", 0.011f) + SettingF("predictionMs", 40.0f) / 1000.0f;
        headHeight_ = SettingF("headHeight", 1.6f);
        streamEyeW_ = SettingI("streamEyeWidth", 1280);
        streamEyeH_ = SettingI("streamEyeHeight", 1280);
        mbps_ = SettingI("bitrateMbps", 40);
        ffmpegPath_ = SettingS("ffmpegPath", "auto");
        encoderPreset_ = SettingS("encoderPreset", "p1");
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
        props_ = c;
        VRProperties()->SetStringProperty(c, Prop_ModelNumber_String, model_.c_str());
        VRProperties()->SetStringProperty(c, Prop_ManufacturerName_String, "OpenCardboard");
        VRProperties()->SetStringProperty(c, Prop_TrackingSystemName_String, "opencardboard");
        VRProperties()->SetStringProperty(c, Prop_RenderModelName_String, "generic_hmd");
        VRProperties()->SetFloatProperty(c, Prop_UserIpdMeters_Float, ipd_);
        VRProperties()->SetFloatProperty(c, Prop_UserHeadToEyeDepthMeters_Float, 0.0f);
        VRProperties()->SetFloatProperty(c, Prop_DisplayFrequency_Float, freq_);
        VRProperties()->SetFloatProperty(c, Prop_SecondsFromVsyncToPhotons_Float, photons_);
        VRProperties()->SetUint64Property(c, Prop_CurrentUniverseId_Uint64, 2);
        if (InitD3D()) {
            VRProperties()->SetUint64Property(c, Prop_GraphicsAdapterLuid_Uint64,
                ((uint64_t)luid_.HighPart << 32) | (uint64_t)luid_.LowPart);
            d3dReady_ = true;
        } else {
            Log("D3D11 init FAILED - direct mode will not work");
        }
        VRProperties()->SetBoolProperty(c, Prop_DriverDirectModeSendsVsyncEvents_Bool, true);
        if (!vsyncThread_.joinable()) {
            stopVsync_ = false;
            vsyncThread_ = std::thread([this] { VsyncLoop(); });
        }
        Log("OpenCardboard HMD activated (object id %u)", objectId);
        return VRInitError_None;
    }
    void Deactivate() { Log("HMD deactivated"); objectId_ = k_unTrackedDeviceIndexInvalid; }
    void EnterStandby() {}
    void* GetComponent(const char* name) {
        Log("GetComponent(%s)", name ? name : "(null)");
        if (name && _stricmp(name, IVRDisplayComponent_Version) == 0)
            return static_cast<IVRDisplayComponent*>(this);
        if (name && _stricmp(name, IVRDriverDirectModeComponent_Version) == 0)
            return static_cast<IVRDriverDirectModeComponent*>(this);
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
    bool IsDisplayOnDesktop() { return false; }
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
        if (!c) {
            streamer_.Stop();
            {
                std::lock_guard<std::mutex> g(mu_);
                havePrev_ = false;
                for (int i = 0; i < 3; i++) angVel_[i] = 0.0;
            }
            if (pad_) { double pp[3] = {0, headHeight_, 0}; pad_->SetHmdPose(q_, pp, false); }
        }
        PushPose();
    }
    void OnHello(const float fl[4], const float fr[4]) {
        Log("phone prefers frustum l=%.2f r=%.2f u=%.2f d=%.2f (not applied yet)", fl[0], fl[1], fl[2], fl[3]);
    }
    void SetSender(std::function<bool(uint16_t, const uint8_t*, uint32_t)> f) { sender_ = f; }
    bool HasD3D() const { return d3dReady_; }
    void SetPad(PadDevice* p) { pad_ = p; }
    void SetIpdMM(float mm) {
        float m = mm / 1000.0f;
        if (m < 0.04f || m > 0.09f) return;
        ipd_ = m;
        if (props_ != k_ulInvalidPropertyContainer) {
            VRProperties()->SetFloatProperty(props_, Prop_UserIpdMeters_Float, m);
            Log("IPD set to %.1f mm (from the phone)", mm);
        }
    }
    void OnPhoneReady() {
        if (!d3dReady_) { Log("no D3D device yet - will retry"); return; }
        if (streamer_.Ready()) { SendStreamConfig(); return; }     // already running
        bool ok = streamer_.Start(dev_.Get(), ctx_.Get(), streamEyeW_, streamEyeH_, (int)(freq_ + 0.5f), mbps_,
                                  ffmpegPath_, encoderPreset_,
                                  [this](const float* rot, const float* pos, bool key, const uint8_t* au, size_t n) {
                                      SendVideo(rot, pos, key, au, n);
                                  });
        if (ok) SendStreamConfig();
    }
    void SendStreamConfig() {
        if (!sender_) return;
        uint8_t p[40] = {0};
        p[0] = 1;   // H.264
        uint16_t w = (uint16_t)(streamEyeW_ * 2), h = (uint16_t)streamEyeH_;
        memcpy(p + 4, &w, 2);
        memcpy(p + 6, &h, 2);
        {
            std::lock_guard<std::mutex> g(mu_);
            memcpy(p + 8, frust_[0], 16);
            memcpy(p + 24, frust_[1], 16);
        }
        sender_(MSG_STREAM_CONFIG, p, 40);
        Log("sent StreamConfig %ux%u", (unsigned)w, (unsigned)h);
    }
    void SendVideo(const float* rot, const float* pos, bool key, const uint8_t* au, size_t n) {
        if (!sender_) return;
        std::vector<uint8_t> buf(56 + n);
        uint32_t seq = ++videoSeq_;
        uint32_t flags = key ? 1u : 0u;
        memcpy(buf.data(), &seq, 4);
        memcpy(buf.data() + 4, &flags, 4);
        memcpy(buf.data() + 8, rot, 36);
        memcpy(buf.data() + 44, pos, 12);
        memcpy(buf.data() + 56, au, n);
        sender_(MSG_VIDEO, buf.data(), (uint32_t)buf.size());
    }
    void OnPose(const float rot[9], const float pos[3]) {
        float m[3][3];
        for (int c = 0; c < 3; c++)
            for (int r = 0; r < 3; r++) m[r][c] = rot[c * 3 + r];   // column-major on the wire
        HmdQuaternion_t q = QuatFromMatrix(m);
        auto now = std::chrono::steady_clock::now();
        double w3[3] = {0, 0, 0};
        if (havePrev_) {
            double dt = std::chrono::duration<double>(now - prevT_).count();
            if (dt > 0.001 && dt < 0.1) {
                HmdQuaternion_t d = QMul(q, QConj(prevQ_));      // world-frame rotation since the last sample
                if (d.w < 0) { d.w = -d.w; d.x = -d.x; d.y = -d.y; d.z = -d.z; }
                double sn = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                if (sn > 1e-9) {
                    double k = 2.0 * std::atan2(sn, d.w) / sn / dt;
                    w3[0] = d.x * k; w3[1] = d.y * k; w3[2] = d.z * k;
                }
            }
        }
        prevQ_ = q;
        prevT_ = now;
        havePrev_ = true;
        {
            std::lock_guard<std::mutex> g(mu_);
            q_ = q;
            for (int i = 0; i < 3; i++) {
                pos_[i] = pos[i];
                angVel_[i] = 0.5 * angVel_[i] + 0.5 * w3[i];     // light smoothing
            }
        }
        if (pad_) {
            double pp[3] = {pos[0], headHeight_ + pos[1], pos[2]};
            pad_->SetHmdPose(q, pp, true);
        }
        PushPose();
    }
    void PushPose() {
        uint32_t id = objectId_;
        if (id != k_unTrackedDeviceIndexInvalid)
            VRServerDriverHost()->TrackedDevicePoseUpdated(id, BuildPose(), sizeof(DriverPose_t));
    }

    // ---------------------------------------------------------- D3D11 + direct mode
    bool InitD3D() {
        ComPtr<IDXGIFactory1> factory;
        if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;
        ComPtr<IDXGIAdapter1> best;
        SIZE_T bestMem = 0;
        for (UINT i = 0;; i++) {
            ComPtr<IDXGIAdapter1> a;
            if (factory->EnumAdapters1(i, &a) == DXGI_ERROR_NOT_FOUND) break;
            DXGI_ADAPTER_DESC1 d;
            a->GetDesc1(&d);
            if (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            if (d.DedicatedVideoMemory >= bestMem) { bestMem = d.DedicatedVideoMemory; best = a; }
        }
        if (!best) return false;
        DXGI_ADAPTER_DESC1 d;
        best->GetDesc1(&d);
        luid_ = d.AdapterLuid;
        char name[256] = {0};
        WideCharToMultiByte(CP_UTF8, 0, d.Description, -1, name, sizeof(name) - 1, nullptr, nullptr);
        Log("using GPU: %s (%llu MB)", name, (unsigned long long)(d.DedicatedVideoMemory >> 20));
        D3D_FEATURE_LEVEL fl;
        HRESULT hr = D3D11CreateDevice(best.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                                       D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                       D3D11_SDK_VERSION, &dev_, &fl, &ctx_);
        if (FAILED(hr)) { Log("D3D11CreateDevice failed: 0x%08lX", (unsigned long)hr); return false; }
        return true;
    }

    void VsyncLoop() {
        using clock = std::chrono::steady_clock;
        double hz = std::max(freq_, 1.0f);
        auto period = std::chrono::duration_cast<clock::duration>(std::chrono::duration<double>(1.0 / hz));
        auto next = clock::now();
        while (!stopVsync_) {
            VRServerDriverHost()->VsyncEvent(0.0);
            next += period;
            std::this_thread::sleep_until(next);
        }
    }

    void Shutdown() {
        streamer_.Stop();
        stopVsync_ = true;
        if (vsyncThread_.joinable()) vsyncThread_.join();
    }

    // IVRDriverDirectModeComponent
    void CreateSwapTextureSet(uint32_t pid, const SwapTextureSetDesc_t* desc, SwapTextureSet_t* out) {
        Log("CreateSwapTextureSet pid=%u %ux%u format=%u samples=%u", pid, desc->nWidth, desc->nHeight,
            desc->nFormat, desc->nSampleCount);
        std::lock_guard<std::mutex> g(d3dMu_);
        D3D11_TEXTURE2D_DESC td = {};
        td.Width = desc->nWidth;
        td.Height = desc->nHeight;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = (DXGI_FORMAT)desc->nFormat;
        td.SampleDesc.Count = desc->nSampleCount;
        td.SampleDesc.Quality = 0;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        td.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
        out->unTextureFlags = 0;
        for (int i = 0; i < 3; i++) {
            out->rSharedTextureHandles[i] = 0;
            if (!dev_) continue;
            ComPtr<ID3D11Texture2D> t;
            HRESULT hr = dev_->CreateTexture2D(&td, nullptr, &t);
            if (FAILED(hr)) { Log("CreateTexture2D failed: 0x%08lX", (unsigned long)hr); continue; }
            ComPtr<IDXGIResource> r;
            t.As(&r);
            HANDLE h = nullptr;
            if (r) r->GetSharedHandle(&h);
            out->rSharedTextureHandles[i] = (SharedTextureHandle_t)(uintptr_t)h;
            SwapTex st;
            st.tex = t;
            st.pid = pid;
            swap_[(uint64_t)(uintptr_t)h] = st;
        }
    }
    void DestroySwapTextureSet(SharedTextureHandle_t h) {
        std::lock_guard<std::mutex> g(d3dMu_);
        streamer_.ForgetTextures();
        swap_.erase((uint64_t)h);
    }
    void DestroyAllSwapTextureSets(uint32_t pid) {
        std::lock_guard<std::mutex> g(d3dMu_);
        streamer_.ForgetTextures();
        for (auto it = swap_.begin(); it != swap_.end();) {
            if (it->second.pid == pid) it = swap_.erase(it); else ++it;
        }
    }
    void GetNextSwapTextureSetIndex(SharedTextureHandle_t sharedTextureHandles[2], uint32_t (*pIndices)[2]) {
        for (int i = 0; i < 2; i++) {
            nextIdx_[i] = (nextIdx_[i] + 1) % 3;
            (*pIndices)[i] = nextIdx_[i];
        }
    }
    void SubmitLayer(const SubmitLayerPerEye_t (&perEye)[2]) {
        if (layerCount_++ == 0) {     // the first layer submitted for a frame is the scene; later ones are overlays
            for (int e = 0; e < 2; e++) {
                lastLayer_[e] = perEye[e].hTexture;
                layerBounds_[e] = perEye[e].bounds;
            }
            const HmdMatrix34_t& m = perEye[0].mHmdPose;
            for (int c = 0; c < 3; c++)
                for (int r = 0; r < 3; r++) layerRot_[c * 3 + r] = m.m[r][c];   // column-major on the wire
        }
    }
    void Present(SharedTextureHandle_t syncTexture) {
        uint64_t n = ++presented_;
        if (n == 1 || n % 300 == 0) {
            Log("direct mode: %llu frames presented", (unsigned long long)n);
        }
        std::lock_guard<std::mutex> g(d3dMu_);
        ComPtr<IDXGIKeyedMutex> km = SyncMutex(syncTexture);
        if (km && SUCCEEDED(km->AcquireSync(0, 10))) {
            if (streamer_.Ready() && layerCount_ > 0) {
                auto a = swap_.find((uint64_t)lastLayer_[0]);
                auto b = swap_.find((uint64_t)lastLayer_[1]);
                if (a != swap_.end() && b != swap_.end()) {
                    const float zeroPos[3] = {0, 0, 0};
                    streamer_.SubmitFrame(a->second.tex.Get(), layerBounds_[0], b->second.tex.Get(),
                                          layerBounds_[1], layerRot_, zeroPos);
                }
            }
            km->ReleaseSync(0);
        }
        layerCount_ = 0;
    }
    void PostPresent(const Throttling_t*) {}
    void GetFrameTiming(DriverDirectMode_FrameTiming*) {}

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
        for (int i = 0; i < 3; i++) p.vecAngularVelocity[i] = connected_ ? angVel_[i] : 0.0;
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

    ComPtr<IDXGIKeyedMutex> SyncMutex(SharedTextureHandle_t h) {
        auto it = syncCache_.find((uint64_t)h);
        if (it != syncCache_.end()) return it->second;
        ComPtr<IDXGIKeyedMutex> km;
        if (dev_ && h) {
            ComPtr<ID3D11Texture2D> t;
            if (SUCCEEDED(dev_->OpenSharedResource((HANDLE)(uintptr_t)h, IID_PPV_ARGS(&t)))) t.As(&km);
        }
        syncCache_[(uint64_t)h] = km;     // cached even when null, so the handle is only opened once
        return km;
    }

    struct SwapTex { ComPtr<ID3D11Texture2D> tex; uint32_t pid = 0; };
    ComPtr<ID3D11Device> dev_;
    ComPtr<ID3D11DeviceContext> ctx_;
    LUID luid_ = {};
    std::map<uint64_t, SwapTex> swap_;
    std::map<uint64_t, ComPtr<IDXGIKeyedMutex>> syncCache_;
    std::mutex d3dMu_;
    uint32_t nextIdx_[2] = {0, 0};
    SharedTextureHandle_t lastLayer_[2] = {0, 0};
    VRTextureBounds_t layerBounds_[2] = {};
    float layerRot_[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    int layerCount_ = 0;
    Streamer streamer_;
    std::function<bool(uint16_t, const uint8_t*, uint32_t)> sender_;
    std::atomic<uint32_t> videoSeq_{0};
    std::atomic<bool> d3dReady_{false};
    PadDevice* pad_ = nullptr;
    HmdQuaternion_t prevQ_ = {1, 0, 0, 0};
    std::chrono::steady_clock::time_point prevT_;
    bool havePrev_ = false;
    double angVel_[3] = {0, 0, 0};
    PropertyContainerHandle_t props_ = k_ulInvalidPropertyContainer;
    std::string encoderPreset_;
    int streamEyeW_ = 1280, streamEyeH_ = 1280, mbps_ = 40;
    std::string ffmpegPath_;
    std::atomic<uint64_t> presented_{0};
    std::thread vsyncThread_;
    std::atomic<bool> stopVsync_{false};
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

    // ---- USB path: ask Apple's USB service (usbmuxd, 127.0.0.1:27015) for a tunnel to the phone app.
    void UsbNote(const std::string& m) {
        if (m != lastUsbNote_) { lastUsbNote_ = m; Log("%s", m.c_str()); }
    }

    static long ParseInt(const std::string& x, const char* key) {
        std::string k = std::string("<key>") + key + "</key>";
        size_t p = x.find(k);
        if (p == std::string::npos) return -1;
        p = x.find("<integer>", p + k.size());
        if (p == std::string::npos) return -1;
        return atol(x.c_str() + p + 9);
    }

    static bool MuxRequest(SOCKET s, const char* type, long deviceId, uint32_t tag, int port, std::string& resp) {
        std::string xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            "<plist version=\"1.0\"><dict>"
            "<key>ClientVersionString</key><string>opencardboard</string>"
            "<key>MessageType</key><string>" + std::string(type) + "</string>"
            "<key>ProgName</key><string>opencardboard</string>";
        if (deviceId >= 0) {
            xml += "<key>DeviceID</key><integer>" + std::to_string(deviceId) + "</integer>"
                   "<key>PortNumber</key><integer>" + std::to_string((int)htons((u_short)port)) + "</integer>";
        }
        xml += "</dict></plist>";
        uint32_t hdr[4] = {(uint32_t)(16 + xml.size()), 1, 8, tag};
        if (send(s, (const char*)hdr, 16, 0) != 16) return false;
        if (send(s, xml.data(), (int)xml.size(), 0) != (int)xml.size()) return false;
        uint32_t rh[4];
        if (!RecvAll(s, (uint8_t*)rh, 16)) return false;
        uint32_t len = rh[0];
        if (len < 16 || len > (1u << 20)) return false;
        resp.assign(len - 16, '\0');
        if (len > 16 && !RecvAll(s, (uint8_t*)&resp[0], (int)(len - 16))) return false;
        return true;
    }

    SOCKET MuxSocket() {
        SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return s;
        sockaddr_in a = {};
        a.sin_family = AF_INET;
        a.sin_port = htons(27015);
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
        DWORD to = 3000;
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof(to));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&to, sizeof(to));
        if (connect(s, (sockaddr*)&a, sizeof(a)) != 0) { closesocket(s); return INVALID_SOCKET; }
        return s;
    }

    SOCKET ConnectUsb() {
        SOCKET s = MuxSocket();
        if (s == INVALID_SOCKET) { UsbNote("usb: Apple's USB service is not reachable (127.0.0.1:27015)"); return s; }
        std::string resp;
        if (!MuxRequest(s, "ListDevices", -1, 1, 0, resp)) {
            closesocket(s);
            UsbNote("usb: no usable reply to ListDevices");
            return INVALID_SOCKET;
        }
        closesocket(s);
        long id = ParseInt(resp, "DeviceID");
        if (id < 0) { UsbNote("usb: no iPhone attached"); return INVALID_SOCKET; }

        SOCKET s2 = MuxSocket();
        if (s2 == INVALID_SOCKET) return s2;
        if (!MuxRequest(s2, "Connect", id, 2, (int)port_, resp)) {
            closesocket(s2);
            UsbNote("usb: no usable reply to Connect");
            return INVALID_SOCKET;
        }
        long code = ParseInt(resp, "Number");
        if (code != 0) {
            closesocket(s2);
            char note[160];
            snprintf(note, sizeof(note), "usb: iPhone found (id %ld) but connecting to the app failed (code %ld) - is OpenCardboard open?", id, code);
            UsbNote(note);
            return INVALID_SOCKET;
        }
        int one = 1;
        setsockopt(s2, IPPROTO_TCP, TCP_NODELAY, (const char*)&one, sizeof(one));
        DWORD to = 3000;
        setsockopt(s2, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof(to));
        UsbNote("usb: connected through the USB cable (no hotspot needed)");
        return s2;
    }

    SOCKET Connect() {
        if (transport_ != "network") {
            SOCKET u = ConnectUsb();
            if (u != INVALID_SOCKET) return u;
        }
        if (transport_ == "usb") return INVALID_SOCKET;
        return ConnectTcp();
    }

    SOCKET ConnectTcp() {
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

public:
    void SetTransport(const std::string& t) { transport_ = t; }
    bool Send(uint16_t type, const uint8_t* payload, uint32_t len) {
        SOCKET s = sock_;
        if (s == INVALID_SOCKET) return false;
        return SendMsg(s, type, payload, len);
    }

private:
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
        bool needStart = false;
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
                float ipdMM;
                memcpy(&ipdMM, payload.data() + 8, 4);
                hmd_->SetIpdMM(ipdMM);
                needStart = true;
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

            if (needStart && hmd_->HasD3D()) {
                needStart = false;
                hmd_->OnPhoneReady();
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
    std::string transport_ = "auto";      // "auto" = USB cable first, then the network address; "usb"; "network"
    std::string lastUsbNote_;
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
        if (SettingB("gamepadBridge", true)) {
            pad_ = new PadDevice();
            bool added = VRServerDriverHost()->TrackedDeviceAdded(pad_->Serial(), TrackedDeviceClass_Controller, pad_);
            Log("gaze pointer added: %d", added ? 1 : 0);
            hmd_->SetPad(pad_);
        }
        hmd_->SetSender([this](uint16_t t, const uint8_t* p, uint32_t n) { return net_.Send(t, p, n); });
        net_.SetTransport(SettingS("phoneTransport", "auto"));
        net_.Start(host, (uint16_t)port, hmd_);
        Log("Provider::Init done");
        return VRInitError_None;
    }
    void Cleanup() {
        Log("Provider::Cleanup begin");
        if (pad_) pad_->Shutdown();
        if (hmd_) hmd_->Shutdown();
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
    PadDevice* pad_ = nullptr;
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
