//
// mini_http.hpp -- minimal HTTP server and JSON helpers for the web mode.
// Shared by sdr/b210/host/dvbs2_b210.cpp and sdr/adrv9364/sw/dvbs2_adrv.cpp (header-only, one translation unit each).
//
#pragma once
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <fstream>
#include <functional>
#include <map>
#include <sstream>
#include <string>
#include "dvbs2_common.hpp"

// JSON number, null when not finite
static std::string jnum(double v, int digits = 2)
{
    if (!std::isfinite(v)) return "null";
    char b[32];
    snprintf(b, sizeof b, "%.*f", digits, v);
    return b;
}
static std::string url_decode(const std::string& s)
{
    std::string o;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '+') o += ' ';
        else if (s[i] == '%' && i + 2 < s.size()) {
            o += char(std::stoi(s.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else o += s[i];
    }
    return o;
}
static std::map<std::string, std::string> parse_query(const std::string& q)
{
    std::map<std::string, std::string> kv;
    std::stringstream ss(q);
    std::string item;
    while (std::getline(ss, item, '&')) {
        size_t e = item.find('=');
        if (e == std::string::npos) continue;
        kv[url_decode(item.substr(0, e))] = url_decode(item.substr(e + 1));
    }
    return kv;
}
static void send_all(int fd, const std::string& s)
{
    size_t off = 0;
    while (off < s.size()) {
        ssize_t w = ::send(fd, s.data() + off, s.size() - off, MSG_NOSIGNAL);
        if (w <= 0) return;
        off += size_t(w);
    }
}
static void reply(int fd, int code, const std::string& type, const std::string& body, const std::string& extra = "")
{
    const char* txt = code == 200 ? "OK" : code == 404 ? "Not Found" : code == 413 ? "Payload Too Large" : "Bad Request";
    std::string h = "HTTP/1.1 " + std::to_string(code) + " " + txt + "\r\nContent-Type: " + type
                    + "\r\nContent-Length: " + std::to_string(body.size()) + "\r\nCache-Control: no-store\r\n" + extra
                    + "Connection: close\r\n\r\n";
    send_all(fd, h + body);
}
static bool read_file(const std::string& path, std::string& out)
{
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}
static std::string safe_name(const std::string& n)
{
    std::string o;
    for (char c : n)
        o += (isalnum((unsigned char)c) || c == '.' || c == '-' || c == '_') ? c : '_';
    if (o.empty() || o[0] == '.') o = "file" + o;
    return o.substr(0, 100);
}

// Serves HTTP on bind_addr:port until stop_signal, one connection at a time: handle(fd) reads the
// request and replies.  any_host is shown instead of 0.0.0.0 in the printed URL.
static void web_server(int port, std::string bind_addr, std::string any_host, std::function<void(int)> handle)
{
    int s = ::socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port   = htons(uint16_t(port));
    if (inet_pton(AF_INET, bind_addr.c_str(), &a.sin_addr) != 1 || ::bind(s, (sockaddr*)&a, sizeof(a)) != 0
        || ::listen(s, 16) != 0) {
        fprintf(stderr, "web: cannot listen on %s:%d (%s)\n", bind_addr.c_str(), port, strerror(errno));
        stop_signal = true;
        return;
    }
    timeval tv{0, 200000};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));   // accept() wakes up to check stop_signal
    fprintf(g_log, "web page: http://%s:%d/\n", (bind_addr == "0.0.0.0" ? any_host : bind_addr).c_str(), port);
    while (!stop_signal) {
        int c = ::accept(s, nullptr, nullptr);
        if (c < 0) continue;
        timeval ct{10, 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &ct, sizeof(ct));
        try {
            handle(c);
        } catch (const std::exception& e) {
            fprintf(stderr, "web: %s\n", e.what());
        }
        ::close(c);
    }
    ::close(s);
}

static std::string exe_dir()
{
    char p[4096];
    ssize_t n = readlink("/proc/self/exe", p, sizeof(p) - 1);
    if (n <= 0) return ".";
    p[n]          = 0;
    std::string s = p;
    return s.substr(0, s.find_last_of('/'));
}
// web page directory: the installed one if it holds index.html, else sdr/host_common/web of the source tree
// (program built in sdr/b210/host/build or sdr/adrv9364/sw/build)
static std::string default_web_root(const std::string& installed)
{
    std::string probe;
    if (read_file(installed + "/index.html", probe)) return installed;
    return exe_dir() + "/../../../host_common/web";
}
static std::string jstr(const std::string& s)
{
    std::string o = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') o += '\\';
        if ((unsigned char)c >= 0x20) o += c;
    }
    return o + "\"";
}
