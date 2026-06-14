// RemoteInputService.swift
// AngelLiveTVOS
//
// 轻量 HTTP 服务，监听本地端口，让手机浏览器通过网页表单向 tvOS 发送文本输入。
// 无需第三方依赖，纯 Network.framework 实现。

import Foundation
import Network
import Observation
import AngelLiveDependencies
import AngelLiveCore

// 输入事件：字段类型 + 内容
// id 每次都是新 UUID,使 SwiftUI 的 onChange(of: lastEvent?.id) 即使在重复提交相同内容时也能触发。
// .config 同时携带 url 和可选 title,避免配置页一次提交时两个连续的 lastEvent 赋值被 SwiftUI 批量合并丢失。
struct RemoteInputEvent: Identifiable {
    enum Field: String {
        case title
        case url
        case search
        case cookie
        case config
    }
    let id = UUID()
    let field: Field
    let value: String
    var url: String? = nil
    var title: String? = nil
}

@Observable
final class RemoteInputService {

    private(set) var isRunning = false
    private(set) var localIPAddress: String = ""
    private(set) var port: UInt16 = 8080

    // 最新收到的输入事件，View 通过 onChange 监听
    private(set) var lastEvent: RemoteInputEvent?

    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        localIPAddress = Common.getWiFiIPAddress() ?? ""
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                    case .failed, .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener.start(queue: .global(qos: .utility))
        } catch {
            Logger.warning("[RemoteInputService] start error: \(error)", category: .sync)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receiveRequest(connection: connection)
    }

    private func receiveRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let raw = String(data: data, encoding: .utf8) ?? ""
            let response = self.processRequest(raw)
            self.sendResponse(connection: connection, body: response)
        }
    }

    private func processRequest(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""

        // POST /input — 接收表单提交，返回 JSON 供前端 JS 消费
        if firstLine.hasPrefix("POST /input") {
            if let bodyLine = raw.components(separatedBy: "\r\n\r\n").last {
                let result = parseFormBody(bodyLine)
                let msg = result.message.replacingOccurrences(of: "\"", with: "\\\"")
                let json = "{\"success\":\(result.success),\"message\":\"\(msg)\"}"
                return "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
            }
            return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"success\":false,\"message\":\"未收到数据\"}"
        }

        // GET /ping — 心跳,供前端轮询展示"已连到 Apple TV"状态
        if firstLine.hasPrefix("GET /ping") {
            let json = "{\"ok\":true}"
            return "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(json.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(json)"
        }

        // GET /search — 搜索输入页
        if firstLine.hasPrefix("GET /search") {
            return htmlResponse(searchPage())
        }

        // GET /cookie — Cookie 输入页
        if firstLine.hasPrefix("GET /cookie") {
            let queryParams = parseQueryParams(from: firstLine)
            let platformTitle = queryParams["platform"] ?? ""
            let hint = queryParams["hint"] ?? ""
            return htmlResponse(cookiePage(platformTitle: platformTitle, hint: hint))
        }

        // GET /config 或 / — 配置页（URL + 标题）
        return htmlResponse(configPage())
    }

    @discardableResult
    private func parseFormBody(_ body: String) -> (success: Bool, message: String) {
        var urlValue: String?
        var titleValue: String?
        var fieldValue: RemoteInputEvent.Field?
        var singleValue = ""

        for pair in body.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let key = kv[0]
            let val = kv[1].replacingOccurrences(of: "+", with: " ")
                           .removingPercentEncoding ?? kv[1]
            switch key {
            case "url_value":   urlValue = val
            case "title_value": titleValue = val
            case "field":       fieldValue = RemoteInputEvent.Field(rawValue: val)
            case "value":       singleValue = val
            default: break
            }
        }

        // 配置页:url + 可选 title。
        // 合并成单个 .config 事件,避免两次 MainActor 赋值被 SwiftUI 批量合并导致 url 丢失。
        if let url = urlValue {
            if url.isEmpty {
                return (false, "地址不能为空")
            }
            let title = titleValue?.isEmpty == false ? titleValue : nil
            let event = RemoteInputEvent(field: .config, value: url, url: url, title: title)
            Task { @MainActor in self.lastEvent = event }
            if let title {
                return (true, "已填入:\(title) / \(url)")
            }
            return (true, "已填入地址:\(url)")
        }

        // 搜索页
        if urlValue == nil, titleValue == nil, let field = fieldValue {
            if singleValue.isEmpty {
                return (false, "内容不能为空")
            }
            let event = RemoteInputEvent(field: field, value: singleValue)
            Task { @MainActor in self.lastEvent = event }
            return (true, "已发送：\(singleValue)")
        }

        return (false, "未识别的表单数据")
    }

    private func sendResponse(connection: NWConnection, body: String) {
        let data = Data(body.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - HTTP Responses

    private func htmlResponse(_ html: String) -> String {
        let bodyData = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        return header + html
    }

    private func redirectResponse() -> String {
        return "HTTP/1.1 303 See Other\r\nLocation: /\r\nConnection: close\r\n\r\n"
    }

    /// Liquid Glass 风格的页面外壳。dark/light 双模式 + 顶部连接状态 + 粘贴板识别 + 提交动画。
    /// - Parameters:
    ///   - documentTitle: 浏览器 tab 标题。
    ///   - pageTitle: 页面主标题(显示在 H1)。
    ///   - subtitle: 副标题描述。
    ///   - body: 主体 HTML(通常是表单卡片 + footer 提示)。
    ///   - showPasteBanner: 是否在顶部展示"粘贴剪贴板链接"横幅(只在含 URL 输入的页面打开)。
    private func pageHTML(documentTitle: String, pageTitle: String, subtitle: String, body: String, showPasteBanner: Bool = false) -> String {
        let pasteBanner = showPasteBanner ? """
        <button id="paste-banner" class="paste-banner" type="button" style="display:none">
          <span class="paste-banner-icon">⤓</span>
          <span class="paste-banner-text">
            <span class="paste-banner-title">粘贴剪贴板里的链接</span>
            <span class="paste-banner-preview">点击读取剪贴板</span>
          </span>
          <span class="paste-banner-dismiss" aria-label="关闭">×</span>
        </button>
        """ : ""

        return """
        <!DOCTYPE html>
        <html lang="zh">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <meta name="theme-color" content="#0c0a1e" media="(prefers-color-scheme: dark)">
        <meta name="theme-color" content="#fff5f0" media="(prefers-color-scheme: light)">
        <title>\(documentTitle)</title>
        <style>
          :root {
            --bg-1: #1a0d2e;
            --bg-2: #0c0a1e;
            --bg-3: #050516;
            --text-1: #f5f5f7;
            --text-2: #a1a1aa;
            --text-3: #71717a;
            --card-bg: rgba(255,255,255,0.06);
            --card-border: rgba(255,255,255,0.12);
            --card-shadow: 0 10px 40px rgba(0,0,0,0.28);
            --input-bg: rgba(255,255,255,0.08);
            --input-bg-focus: rgba(255,255,255,0.14);
            --accent: #FF815E;
            --accent-2: #ff5a3c;
            --accent-soft: rgba(255,129,94,0.16);
            --success: #30d158;
            --error: #ff453a;
          }
          @media (prefers-color-scheme: light) {
            :root {
              --bg-1: #ffe9dc;
              --bg-2: #fff6ef;
              --bg-3: #f6f6f8;
              --text-1: #1c1c1e;
              --text-2: #5a5a63;
              --text-3: #8e8e93;
              --card-bg: rgba(255,255,255,0.7);
              --card-border: rgba(0,0,0,0.06);
              --card-shadow: 0 10px 30px rgba(140,80,40,0.10);
              --input-bg: rgba(255,255,255,0.78);
              --input-bg-focus: #ffffff;
              --accent-soft: rgba(255,129,94,0.14);
            }
          }
          * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
          html, body { min-height: 100vh; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            background: radial-gradient(circle at 20% 0%, var(--bg-1) 0%, var(--bg-2) 45%, var(--bg-3) 100%);
            background-attachment: fixed;
            color: var(--text-1);
            padding: max(20px, env(safe-area-inset-top)) 20px max(28px, env(safe-area-inset-bottom));
            font-size: 17px;
            line-height: 1.45;
            -webkit-font-smoothing: antialiased;
          }
          .container { max-width: 540px; margin: 0 auto; }
          .app-header {
            display: flex; align-items: center; justify-content: space-between;
            margin-bottom: 28px;
          }
          .brand { display: flex; align-items: center; gap: 10px; }
          .brand-mark {
            width: 32px; height: 32px; border-radius: 9px;
            background: linear-gradient(135deg, var(--accent), var(--accent-2));
            display: grid; place-items: center;
            font-weight: 700; color: white; font-size: 16px;
            box-shadow: 0 4px 14px rgba(255,129,94,0.45);
            font-family: ui-serif, "Times New Roman", serif;
            letter-spacing: -0.02em;
          }
          .brand-name {
            font-size: 15px; font-weight: 600; letter-spacing: -0.01em; color: var(--text-1);
          }
          .status-pill {
            display: inline-flex; align-items: center; gap: 7px;
            padding: 7px 12px; border-radius: 999px;
            background: var(--card-bg); border: 1px solid var(--card-border);
            font-size: 12px; font-weight: 500; color: var(--text-2);
            backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
          }
          .status-dot {
            width: 7px; height: 7px; border-radius: 50%;
            background: var(--success); box-shadow: 0 0 8px currentColor;
            transition: background 0.2s, color 0.2s;
          }
          .status-pill .status-dot { color: var(--success); }
          .status-pill.offline .status-dot { background: var(--text-3); color: var(--text-3); box-shadow: none; }
          .status-pill.offline { color: var(--text-3); }

          .page-title {
            font-size: 30px; font-weight: 700; letter-spacing: -0.02em;
            margin-bottom: 6px; color: var(--text-1);
          }
          .page-subtitle {
            color: var(--text-2); font-size: 15px; margin-bottom: 24px; line-height: 1.45;
          }

          .card {
            background: var(--card-bg); border: 1px solid var(--card-border);
            backdrop-filter: blur(30px) saturate(140%); -webkit-backdrop-filter: blur(30px) saturate(140%);
            border-radius: 20px; padding: 22px;
            box-shadow: var(--card-shadow);
            margin-bottom: 16px;
          }

          .field { margin-bottom: 16px; }
          .field:last-of-type { margin-bottom: 18px; }
          .field-label {
            display: flex; align-items: center; gap: 8px;
            font-size: 12px; font-weight: 600; color: var(--text-2);
            margin-bottom: 8px;
            text-transform: uppercase; letter-spacing: 0.06em;
          }
          .field-label .optional {
            color: var(--text-3); font-weight: 400; text-transform: none; letter-spacing: 0;
          }

          .input, .textarea {
            width: 100%;
            background: var(--input-bg); border: 1.5px solid transparent;
            border-radius: 12px; color: var(--text-1);
            font-size: 16px; padding: 14px 16px; outline: none;
            font-family: inherit;
            transition: background 0.15s, border-color 0.15s;
            -webkit-appearance: none;
          }
          .input:focus, .textarea:focus {
            background: var(--input-bg-focus); border-color: var(--accent);
          }
          .input::placeholder, .textarea::placeholder { color: var(--text-3); }
          .textarea {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 14px; min-height: 140px; resize: vertical;
          }

          .btn-primary {
            width: 100%; position: relative; overflow: hidden;
            background: linear-gradient(135deg, var(--accent), var(--accent-2));
            color: white; border: none; border-radius: 14px;
            font-size: 17px; font-weight: 600; padding: 16px;
            letter-spacing: -0.01em;
            box-shadow: 0 6px 18px rgba(255,129,94,0.35);
            transition: transform 0.12s, opacity 0.2s, box-shadow 0.2s;
            -webkit-appearance: none; cursor: pointer;
            font-family: inherit;
          }
          .btn-primary:active:not(:disabled) { transform: scale(0.985); box-shadow: 0 4px 10px rgba(255,129,94,0.30); }
          .btn-primary:disabled { opacity: 0.55; cursor: default; }
          .btn-primary.is-success {
            background: var(--success);
            box-shadow: 0 6px 18px rgba(48,209,88,0.35);
          }
          .btn-label, .btn-check {
            display: inline-flex; align-items: center; justify-content: center; gap: 6px;
            transition: opacity 0.22s ease, transform 0.22s ease;
          }
          .btn-check {
            position: absolute; inset: 0;
            opacity: 0; transform: scale(0.85);
            pointer-events: none;
          }
          .btn-primary.is-success .btn-label { opacity: 0; transform: scale(0.92); }
          .btn-primary.is-success .btn-check { opacity: 1; transform: scale(1); }

          .result {
            font-size: 13px; margin-top: 12px; min-height: 18px;
            word-break: break-all; white-space: pre-wrap;
          }
          .result.ok { color: var(--success); }
          .result.err { color: var(--error); }

          .footer-hint {
            text-align: center; margin-top: 24px;
            font-size: 13px; color: var(--text-3); line-height: 1.55;
          }
          .footer-hint code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            background: var(--card-bg); border: 1px solid var(--card-border);
            border-radius: 5px; padding: 1px 6px; font-size: 12px; color: var(--text-2);
          }

          .paste-banner {
            display: flex; align-items: center; gap: 12px;
            width: 100%; background: var(--accent-soft);
            border: 1px solid transparent; border-radius: 14px;
            padding: 12px 14px; margin-bottom: 16px;
            font-family: inherit; font-size: 14px; text-align: left;
            cursor: pointer; -webkit-appearance: none;
            color: var(--text-1);
            animation: slidein 0.35s ease;
          }
          .paste-banner-icon {
            width: 32px; height: 32px; border-radius: 9px; flex-shrink: 0;
            background: var(--accent); color: white;
            display: grid; place-items: center;
            font-size: 16px; font-weight: 700;
          }
          .paste-banner-text { flex: 1; min-width: 0; display: flex; flex-direction: column; }
          .paste-banner-title { color: var(--accent); font-weight: 600; font-size: 13px; }
          .paste-banner-preview {
            color: var(--text-2); font-size: 12px; margin-top: 2px;
            overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
          }
          .paste-banner-dismiss {
            color: var(--text-3); font-size: 20px; line-height: 1;
            padding: 4px 8px; flex-shrink: 0;
          }
          @keyframes slidein {
            from { opacity: 0; transform: translateY(-6px); }
            to { opacity: 1; transform: translateY(0); }
          }
        </style>
        </head>
        <body>
        <div class="container">
          <div class="app-header">
            <div class="brand">
              <div class="brand-mark">A</div>
              <div class="brand-name">Angel Live</div>
            </div>
            <div class="status-pill" id="status-pill">
              <span class="status-dot"></span>
              <span class="status-text">连接中…</span>
            </div>
          </div>

          <h1 class="page-title">\(pageTitle)</h1>
          <p class="page-subtitle">\(subtitle)</p>

          \(pasteBanner)

          \(body)
        </div>

        <script>
        (function(){
          // 心跳:每 4s 探测 /ping,连续 2 次失败再标记离线,避免网络抖动误报。
          var statusEl = document.getElementById('status-pill');
          var statusText = statusEl ? statusEl.querySelector('.status-text') : null;
          var failCount = 0;
          function setOnline(online){
            if (!statusEl) return;
            if (online) {
              statusEl.classList.remove('offline');
              statusText.textContent = '已连到 Apple TV';
            } else {
              statusEl.classList.add('offline');
              statusText.textContent = '已断开';
            }
          }
          function ping(){
            var ctrl = ('AbortController' in window) ? new AbortController() : null;
            var timer = setTimeout(function(){ if (ctrl) ctrl.abort(); }, 2500);
            fetch('/ping', { method: 'GET', cache: 'no-store', signal: ctrl ? ctrl.signal : undefined })
              .then(function(r){
                clearTimeout(timer);
                if (r.ok) { failCount = 0; setOnline(true); }
                else { failCount++; if (failCount >= 2) setOnline(false); }
              })
              .catch(function(){
                clearTimeout(timer);
                failCount++; if (failCount >= 2) setOnline(false);
              });
          }
          ping();
          setInterval(ping, 4000);

          // 表单提交:成功时按钮变 √,1.4s 后清空输入框并复原,失败时显示红色错误。
          window.submitForm = function(form, resultId){
            var data = new FormData(form);
            var params = new URLSearchParams(data).toString();
            var result = document.getElementById(resultId);
            var btn = form.querySelector('.btn-primary');
            result.className = 'result'; result.textContent = '';
            btn.disabled = true;
            fetch('/input', {
              method: 'POST',
              headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
              body: params
            })
            .then(function(r){ return r.json(); })
            .then(function(j){
              if (j.success) {
                btn.classList.add('is-success');
                result.className = 'result ok';
                result.textContent = j.message || '已同步到 Apple TV';
                setTimeout(function(){
                  form.querySelectorAll('input[type=text], textarea').forEach(function(el){ el.value = ''; });
                  btn.classList.remove('is-success');
                  btn.disabled = false;
                }, 1400);
              } else {
                result.className = 'result err';
                result.textContent = j.message || '发送失败';
                btn.disabled = false;
              }
            })
            .catch(function(){
              result.className = 'result err';
              result.textContent = '发送失败,请重试';
              btn.disabled = false;
            });
            return false;
          };

          // 粘贴板识别:点击 banner 才会读剪贴板(iOS Safari 需用户手势)。
          // 读到 http(s) 链接才填入并隐藏,否则把 banner 转成"剪贴板没有链接"短暂提示。
          var paste = document.getElementById('paste-banner');
          if (paste && navigator.clipboard && navigator.clipboard.readText) {
            paste.style.display = 'flex';
            paste.addEventListener('click', function(e){
              if (e.target.classList.contains('paste-banner-dismiss')) {
                paste.style.display = 'none';
                return;
              }
              navigator.clipboard.readText().then(function(text){
                var trimmed = (text || '').trim();
                if (/^https?:\\/\\/\\S+/i.test(trimmed)) {
                  var target = document.querySelector('input[name="url_value"], input[name="value"]');
                  if (target) { target.value = trimmed; target.focus(); target.blur(); }
                  paste.style.display = 'none';
                } else {
                  paste.querySelector('.paste-banner-title').textContent = '剪贴板没有链接';
                  paste.querySelector('.paste-banner-preview').textContent = '复制一个 http(s) 链接后再试';
                }
              }).catch(function(){
                // iOS Safari 拒绝读取时静默隐藏 banner,不打扰用户。
                paste.style.display = 'none';
              });
            });
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    private func configPage() -> String {
        pageHTML(
            documentTitle: "Angel Live · 添加视频",
            pageTitle: "添加视频",
            subtitle: "输入视频地址,提交后自动填入 Apple TV。",
            body: """
            <form class="card" onsubmit="return submitForm(this,'r1')">
              <div class="field">
                <label class="field-label">收藏标题 <span class="optional">可选</span></label>
                <input class="input" type="text" name="title_value" placeholder="给视频起个名字" autocomplete="off" autocapitalize="off" autocorrect="off">
              </div>
              <div class="field">
                <label class="field-label">视频地址</label>
                <input class="input" type="text" name="url_value" placeholder="https://... 或 .json 订阅" autocomplete="off" autocapitalize="off" autocorrect="off" inputmode="url" spellcheck="false">
              </div>
              <button class="btn-primary" type="submit">
                <span class="btn-label">填入 Apple TV</span>
                <span class="btn-check">✓ 已同步</span>
              </button>
              <p class="result" id="r1"></p>
            </form>
            <p class="footer-hint">支持视频链接、<code>.json</code> 订阅地址或兑换码</p>
            """,
            showPasteBanner: true
        )
    }

    private func searchPage() -> String {
        pageHTML(
            documentTitle: "Angel Live · 搜索",
            pageTitle: "远程搜索",
            subtitle: "输入主播名、链接或分享口令,提交后会发送到 Apple TV 搜索框。",
            body: """
            <form class="card" onsubmit="return submitForm(this,'r1')">
              <input type="hidden" name="field" value="search">
              <div class="field">
                <label class="field-label">搜索内容</label>
                <input class="input" type="text" name="value" placeholder="主播名 / 链接 / 分享口令" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false">
              </div>
              <button class="btn-primary" type="submit">
                <span class="btn-label">发送到搜索框</span>
                <span class="btn-check">✓ 已同步</span>
              </button>
              <p class="result" id="r1"></p>
            </form>
            <p class="footer-hint">支持主播昵称、房间链接或第三方分享口令</p>
            """,
            showPasteBanner: true
        )
    }

    // MARK: - Cookie 输入页

    private func cookiePage(platformTitle: String, hint: String) -> String {
        let platformLabel = platformTitle.isEmpty ? "Cookie" : "\(platformTitle) Cookie"
        let escapedHint = hint
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let hintBlock = escapedHint.isEmpty ? "" : """
        <div class="field-label" style="margin-top:6px;font-weight:500;color:var(--text-2);text-transform:none;letter-spacing:0;">
          提示:\(escapedHint)
        </div>
        """
        return pageHTML(
            documentTitle: "Angel Live · 输入 \(platformLabel)",
            pageTitle: "输入 \(platformLabel)",
            subtitle: "粘贴完整的 Cookie 字符串,Apple TV 会自动验证。",
            body: """
            <form class="card" onsubmit="return submitForm(this,'r1')">
              <input type="hidden" name="field" value="cookie">
              <div class="field">
                <label class="field-label">Cookie 字符串</label>
                <textarea class="textarea" name="value" rows="6" placeholder="在这里粘贴 Cookie..." autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false"></textarea>
              </div>
              \(hintBlock)
              <button class="btn-primary" type="submit">
                <span class="btn-label">发送到 Apple TV</span>
                <span class="btn-check">✓ 已同步</span>
              </button>
              <p class="result" id="r1"></p>
            </form>
            <p class="footer-hint">Cookie 仅在本机局域网传输,Apple TV 收到后会立即验证</p>
            """,
            showPasteBanner: false
        )
    }

    // MARK: - URL Query 解析

    private func parseQueryParams(from requestLine: String) -> [String: String] {
        // requestLine: "GET /cookie?platform=xx&hint=yy HTTP/1.1"
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2, let urlComponents = URLComponents(string: parts[1]) else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in urlComponents.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    // MARK: - 获取本机局域网 IP（使用 Common.getWiFiIPAddress）
}

