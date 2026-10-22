using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class Wrapper {
  const string LogPath = @"D:\Codex\eh-proxy.log";
  const string ExtOrigin = "chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg";
  static int realWsPort = 0;
  static readonly object portLock = new object();
  static readonly object stdoutLock = new object();
  static Stream browserStdout;
  static readonly Regex WsUrl = new Regex(@"ws://127\.0\.0\.1:(\d+)", RegexOptions.Compiled);

  public static int Main(string[] args) {
    try {
      Log("==== wrapper start pid=" + Process.GetCurrentProcess().Id + " ====");
      var dir = AppDomain.CurrentDomain.BaseDirectory;
      var real = Path.Combine(dir, "extension-host.real.exe");
      if (!File.Exists(real)) return 1;

      var listener = new TcpListener(IPAddress.Loopback, 0);
      listener.Start();
      int proxyPort = ((IPEndPoint)listener.LocalEndpoint).Port;
      Log("proxy listen " + proxyPort);
      ThreadPool.QueueUserWorkItem(_ => AcceptLoop(listener));

      var psi = new ProcessStartInfo();
      psi.FileName = real;
      psi.Arguments = QuoteArgs(RewriteSpawnArgs(args));
      psi.UseShellExecute = false;
      psi.RedirectStandardInput = true;
      psi.RedirectStandardOutput = true;
      psi.RedirectStandardError = true;
      psi.CreateNoWindow = true;
      Log("spawn " + psi.Arguments);
      try {
        Log("ppid-hint " + Process.GetCurrentProcess().Id + " parent-name extension-host");
        var names = Environment.GetEnvironmentVariables();
        Log("env EDGEWEBVIEW=" + (Environment.GetEnvironmentVariable("EDGE_WEBVIEW_VERSION") ?? ""));
        Log("env CHROME_VERSION=" + (Environment.GetEnvironmentVariable("CHROME_VERSION") ?? ""));
      } catch {}

      var child = Process.Start(psi);
      if (child == null) { Log("Process.Start returned null"); return 1; }
      child.ErrorDataReceived += (s, e) => { if (e.Data != null) { Console.Error.WriteLine(e.Data); Log("stderr " + e.Data); } };
      child.BeginErrorReadLine();
      Log("child pid " + child.Id);

      var stdin = Console.OpenStandardInput();
      var stdout = Console.OpenStandardOutput();
      browserStdout = stdout;
      var t = new Thread(() => ForwardNative(stdin, child.StandardInput.BaseStream, 0));
      t.IsBackground = true;
      t.Start();
      ForwardNative(child.StandardOutput.BaseStream, stdout, proxyPort);
      Log("stdout pump ended, child exited=" + child.HasExited + (child.HasExited ? " code=" + child.ExitCode : ""));
      try { child.Kill(); } catch {}
      return 0;
    } catch (Exception ex) {
      Log(ex.ToString());
      return 1;
    }
  }

  static string[] RewriteSpawnArgs(string[] args) {
    const string EdgeOrigin = "chrome-extension://odlomjlbamekndcpllcnffbgeohgkmjh";
    var copy = (string[])args.Clone();
    for (int i = 0; i < copy.Length; i++) {
      var a = copy[i].TrimEnd('/');
      if (a.Equals(EdgeOrigin, StringComparison.OrdinalIgnoreCase) ||
          a.Equals(EdgeOrigin + "/", StringComparison.OrdinalIgnoreCase) ||
          a.IndexOf("odlomjlbamekndcpllcnffbgeohgkmjh", StringComparison.OrdinalIgnoreCase) >= 0) {
        copy[i] = ExtOrigin;
        Log("rewrite spawn origin " + a + " -> " + ExtOrigin);
      }
    }
    return copy;
  }

  static string QuoteArgs(string[] args) {
    var sb = new StringBuilder();
    for (int i = 0; i < args.Length; i++) {
      if (i > 0) sb.Append(' ');
      var a = args[i];
      if (a.StartsWith("chrome-extension://", StringComparison.OrdinalIgnoreCase) && a.EndsWith("/"))
        a = a.TrimEnd('/');
      sb.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
    }
    return sb.ToString();
  }

  static void ForwardNative(Stream input, Stream output, int rewritePort) {
    var hdr = new byte[4];
    while (true) {
      if (!ReadExact(input, hdr, 4)) { Log("native read hdr eof rewritePort=" + rewritePort); return; }
      int n = BitConverter.ToInt32(hdr, 0);
      if (n < 0 || n > 32 * 1024 * 1024) return;
      var payload = new byte[n];
      if (!ReadExact(input, payload, n)) return;
      if (rewritePort > 0) payload = Rewrite(payload, rewritePort);
      string preview = null;
      try {
        preview = Encoding.UTF8.GetString(payload);
        var show = preview.Length > 240 ? preview.Substring(0, 240) : preview;
        Log((rewritePort > 0 ? "host->ext " : "ext->host ") + payload.Length + " " + show);
      } catch {}
      if (rewritePort == 0 && preview != null && preview.IndexOf("\"method\":\"ping\"", StringComparison.Ordinal) >= 0) {
        var pong = Encoding.UTF8.GetBytes(BuildPingResult(preview));
        Log("inject pong " + Encoding.UTF8.GetString(pong));
        WriteNative(browserStdout ?? Console.OpenStandardOutput(), pong);
      }
      WriteNative(output, payload);
    }
  }

  static void WriteNative(Stream output, byte[] payload) {
    lock (stdoutLock) {
      output.Write(BitConverter.GetBytes(payload.Length), 0, 4);
      output.Write(payload, 0, payload.Length);
      output.Flush();
    }
  }

  static string BuildPingResult(string request) {
    var m = Regex.Match(request, "\"id\"\\s*:\\s*(\\d+)");
    var id = m.Success ? m.Groups[1].Value : "1";
    return "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":{}}";
  }

  static byte[] Rewrite(byte[] payload, int proxyPort) {
    string text;
    try { text = Encoding.UTF8.GetString(payload); }
    catch { return payload; }
    var m = WsUrl.Match(text);
    if (m.Success) {
      lock (portLock) {
        if (realWsPort == 0) realWsPort = int.Parse(m.Groups[1].Value);
      }
      Log("rewrite " + m.Value + " -> " + proxyPort + " real=" + realWsPort);
      text = WsUrl.Replace(text, "ws://127.0.0.1:" + proxyPort);
      return Encoding.UTF8.GetBytes(text);
    }
    return payload;
  }

  static bool ReadExact(Stream s, byte[] buf, int len) {
    int off = 0;
    while (off < len) {
      int r = s.Read(buf, off, len - off);
      if (r <= 0) return false;
      off += r;
    }
    return true;
  }

  static void AcceptLoop(TcpListener listener) {
    while (true) {
      TcpClient client;
      try { client = listener.AcceptTcpClient(); }
      catch { return; }
      ThreadPool.QueueUserWorkItem(_ => HandleClient(client));
    }
  }

  static void HandleClient(TcpClient client) {
    TcpClient backend = null;
    try {
      int bp;
      lock (portLock) bp = realWsPort;
      if (bp == 0) { client.Close(); return; }
      var c = client.GetStream();
      var header = ReadHeader(c);
      if (header == null) return;
      var rewritten = RewriteClientHeaders(header, bp);
      backend = new TcpClient();
      backend.NoDelay = true;
      backend.Connect(IPAddress.Loopback, bp);
      var b = backend.GetStream();
      b.Write(rewritten, 0, rewritten.Length);
      b.Flush();
      var first = new byte[256];
      int n = b.Read(first, 0, first.Length);
      if (n > 0) {
        var line = Encoding.ASCII.GetString(first, 0, n);
        int cut = line.IndexOf("\r\n");
        Log("backend status " + (cut > 0 ? line.Substring(0, cut) : line.Replace("\r"," ").Replace("\n"," ")));
        c.Write(first, 0, n);
        c.Flush();
      } else {
        Log("backend closed with no handshake response");
      }
      var t = new Thread(() => CopyStream(c, b));
      t.IsBackground = true;
      t.Start();
      CopyStream(b, c);
    } catch (Exception ex) {
      Log("handle " + ex.Message);
    } finally {
      try { client.Close(); } catch {}
      try { if (backend != null) backend.Close(); } catch {}
    }
  }

  static byte[] ReadHeader(NetworkStream s) {
    var ms = new MemoryStream();
    var buf = new byte[1];
    while (ms.Length < 1024 * 1024) {
      int r = s.Read(buf, 0, 1);
      if (r <= 0) return null;
      ms.WriteByte(buf[0]);
      if (ms.Length >= 4) {
        var arr = ms.ToArray();
        int n = arr.Length;
        if (arr[n - 4] == 13 && arr[n - 3] == 10 && arr[n - 2] == 13 && arr[n - 1] == 10)
          return arr;
      }
    }
    return null;
  }

  static byte[] RewriteClientHeaders(byte[] header, int backendPort) {
    var text = Encoding.ASCII.GetString(header);
    var lines = text.Split(new[] { "\r\n" }, StringSplitOptions.None);
    var sb = new StringBuilder();
    bool sawHost = false;
    bool sawOrigin = false;
    foreach (var line in lines) {
      if (line.Length == 0) continue;
      var low = line.ToLowerInvariant();
      if (low.StartsWith("sec-websocket-extensions:")) continue;
      if (low.StartsWith("origin:")) {
        sb.Append(line).Append("\r\n");
        sawOrigin = true;
        continue;
      }
      if (low.StartsWith("host:")) {
        sb.Append("Host: 127.0.0.1:").Append(backendPort).Append("\r\n");
        sawHost = true;
        continue;
      }
      sb.Append(line).Append("\r\n");
    }
    if (!sawHost) sb.Append("Host: 127.0.0.1:").Append(backendPort).Append("\r\n");
    sb.Append("\r\n");
    var outb = Encoding.ASCII.GetBytes(sb.ToString());
    Log("fwd backend=" + backendPort + "\n" + sb.ToString() + "----");
    return outb;
  }

  static void CopyStream(Stream a, Stream b) {
    var buf = new byte[8192];
    try {
      while (true) {
        int n = a.Read(buf, 0, buf.Length);
        if (n <= 0) break;
        b.Write(buf, 0, n);
        b.Flush();
      }
    } catch {}
  }

  static void Log(string s) {
    try { File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss.fff ") + s + "\n"); } catch {}
  }
}
