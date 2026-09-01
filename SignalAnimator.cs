// Claude Signal: SDK-Streaming-Animator fuer OpenRGB (Port 6742).
// Liest state.txt (vom Overlay geschrieben) und rendert Wellen-/Puls-Effekte
// direkt auf die LEDs der angeschlossenen Geraete. Kein Fenster, keine Konsole
// (/target:winexe). Kompiliert mit dem im .NET Framework mitgelieferten csc.exe
// (siehe install.sh) -- bewusst konservatives C# (kein string-interpolation,
// kein null-konditionaler Operator) fuer maximale Kompatibilitaet.
//
// Wichtige Erkenntnis aus Live-Tests (siehe Update 10 im Spec-Dokument):
// Eine EINZELNE dauerhafte SDK-Verbindung, auf der viele LED-Update-Pakete
// nacheinander gesendet werden, wird vom OpenRGB-Server nach 1-2 Paketen
// sauber geschlossen (kein Absturz, aber auch kein Streaming moeglich).
// Fix: fuer JEDES Update-Paket (pro Zone, pro Frame) eine frische, kurzlebige
// TCP-Verbindung oeffnen -> senden -> schliessen. Lokal ueber Loopback dauert
// ein voller Connect+Handshake+Send+Close-Zyklus < 1 ms -- das reicht mit
// riesigem Puffer fuer 20 FPS.

using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;

class SignalAnimator
{
    // --- OpenRGB SDK-Protokoll ---
    const string Magic = "ORGB";
    const string HostAddr = "127.0.0.1";
    const int Port = 6742;
    const int ClientProtocolVersion = 1; // haelt das Controller-Data-Layout einfach (keine Brightness-Felder)

    const uint PKT_REQUEST_CONTROLLER_COUNT = 0;
    const uint PKT_REQUEST_CONTROLLER_DATA = 1;
    const uint PKT_REQUEST_PROTOCOL_VERSION = 40;
    const uint PKT_SET_CLIENT_NAME = 50;
    const uint PKT_RGBCONTROLLER_UPDATEZONELEDS = 1051;
    const uint PKT_RGBCONTROLLER_SETCUSTOMMODE = 1100;

    const int FrameIntervalMs = 50; // 20 FPS
    const int StaleMs = 10000;
    const int SocketTimeoutMs = 2000;

    static Mutex mutex;
    static string baseDir;
    static string stateFile;
    static string configFile;
    static string logFile;
    static bool allRgbDevices = false;

    static List<string> logLines = new List<string>();
    static string lastLoggedState = "";
    static string lastKnownState = "gray";
    static long frameCount = 0;

    class ZoneInfo
    {
        public int Index;
        public int LedCount;
    }

    class ControllerInfo
    {
        public int Index;
        public int TotalLeds;
        public List<ZoneInfo> Zones;
    }

    static List<ControllerInfo> controllers = new List<ControllerInfo>();

    static int Main()
    {
        bool createdNew;
        try
        {
            mutex = new Mutex(false, "Local\\ClaudeSignalAnimatorSingleton", out createdNew);
            bool acquired = createdNew;
            if (!acquired)
            {
                try { acquired = mutex.WaitOne(0); } catch (AbandonedMutexException) { acquired = true; }
            }
            if (!acquired) return 0;
        }
        catch
        {
            return 0;
        }

        try
        {
            RunLoop();
        }
        finally
        {
            try { mutex.ReleaseMutex(); } catch { }
        }
        return 0;
    }

    static void RunLoop()
    {
        string localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        baseDir = Path.Combine(localAppData, "ClaudeSignal");
        stateFile = Path.Combine(baseDir, "state.txt");
        configFile = Path.Combine(baseDir, "config.json");
        logFile = Path.Combine(baseDir, "animator.log");

        try { Directory.CreateDirectory(baseDir); } catch { }

        logLines.Clear();
        Log("SignalAnimator gestartet");

        ReadConfig();
        Log("Konfiguration: AllRgbDevices=" + allRgbDevices);

        bool haveControllers = false;
        long startMs = NowMs();

        while (true)
        {
            if (!haveControllers)
            {
                haveControllers = RefreshControllers();
                if (haveControllers)
                {
                    EnsureDirectMode();
                    Log("Verbunden: " + controllers.Count + " Controller, " + TotalLedsSummary());
                }
                else
                {
                    Thread.Sleep(3000);
                    continue;
                }
            }

            try
            {
                string state = ReadState();
                if (state != lastLoggedState)
                {
                    Log("Zustandswechsel: " + lastLoggedState + " -> " + state);
                    lastLoggedState = state;
                }

                long t = NowMs() - startMs;
                bool allOk = true;

                for (int ci = 0; ci < controllers.Count; ci++)
                {
                    ControllerInfo c = controllers[ci];
                    byte[] colorsAll = BuildFrame(state, t, c.TotalLeds);
                    int offset = 0;
                    for (int zi = 0; zi < c.Zones.Count; zi++)
                    {
                        ZoneInfo z = c.Zones[zi];
                        if (z.LedCount <= 0) { continue; }
                        byte[] slice = new byte[z.LedCount * 4];
                        Array.Copy(colorsAll, offset * 4, slice, 0, z.LedCount * 4);
                        offset += z.LedCount;
                        bool ok = SendZoneUpdate(c.Index, z.Index, z.LedCount, slice);
                        if (!ok) { allOk = false; }
                    }
                }

                if (!allOk)
                {
                    haveControllers = false;
                    Log("Verbindung verloren -- naechster Zyklus versucht Neuverbindung");
                }

                frameCount++;
                if (frameCount % 100 == 0)
                {
                    Log("Herzschlag: zustand=" + state + " frames=" + frameCount);
                }
            }
            catch (Exception ex)
            {
                Log("Fehler in der Hauptschleife: " + ex.Message);
                haveControllers = false;
            }

            Thread.Sleep(FrameIntervalMs);
        }
    }

    // ---------------------------------------------------------------
    // Logging: bewusst einfach gehalten -- bei jedem nennenswerten
    // Ereignis (nicht bei jedem Frame) wird die GESAMTE Log-Datei neu
    // geschrieben, begrenzt auf die letzten 80 Zeilen (< 100 Zeilen).
    // ---------------------------------------------------------------
    static void Log(string msg)
    {
        try
        {
            string line = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss") + " " + msg;
            logLines.Add(line);
            while (logLines.Count > 80) { logLines.RemoveAt(0); }
            File.WriteAllText(logFile, string.Join(Environment.NewLine, logLines.ToArray()) + Environment.NewLine);
        }
        catch { }
    }

    static string TotalLedsSummary()
    {
        string s = "";
        for (int i = 0; i < controllers.Count; i++)
        {
            if (i > 0) { s += ", "; }
            s += "Geraet " + controllers[i].Index + "=" + controllers[i].TotalLeds + " LEDs";
        }
        return s;
    }

    static long NowMs()
    {
        TimeSpan diff = DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        return (long)diff.TotalMilliseconds;
    }

    // ---------------------------------------------------------------
    // config.json: nur "AllRgbDevices": true interessiert -- naiver
    // String-Check reicht, die Datei ist maschinengeneriert.
    // ---------------------------------------------------------------
    static void ReadConfig()
    {
        try
        {
            if (!File.Exists(configFile)) { return; }
            string content = File.ReadAllText(configFile);
            string compact = content.Replace(" ", "").Replace("\r", "").Replace("\n", "").Replace("\t", "");
            allRgbDevices = compact.IndexOf("\"AllRgbDevices\":true", StringComparison.OrdinalIgnoreCase) >= 0;
        }
        catch (Exception ex)
        {
            Log("config.json nicht lesbar: " + ex.Message);
        }
    }

    // ---------------------------------------------------------------
    // state.txt: Format "<zustand> <epochMs>". Sharing-Konflikte werden
    // toleriert (kurzer Retry), sonst bleibt der letzte bekannte Zustand.
    // Aelter als 10 s oder fehlend/kaputt -> "gray".
    // ---------------------------------------------------------------
    static string ReadState()
    {
        string content = null;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                if (!File.Exists(stateFile)) { return "gray"; }
                using (FileStream fs = new FileStream(stateFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (StreamReader sr = new StreamReader(fs))
                {
                    content = sr.ReadToEnd();
                }
                break;
            }
            catch (IOException)
            {
                Thread.Sleep(20);
            }
            catch (Exception)
            {
                break;
            }
        }

        if (content == null) { return lastKnownState; }

        content = content.Trim();
        string[] parts = content.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) { return lastKnownState; }

        long epochMs;
        if (!long.TryParse(parts[1], out epochMs)) { return lastKnownState; }

        if (NowMs() - epochMs > StaleMs) { return "gray"; }

        lastKnownState = parts[0];
        return lastKnownState;
    }

    // ---------------------------------------------------------------
    // Netzwerk-Grundfunktionen
    // ---------------------------------------------------------------
    static void SendPacket(NetworkStream ns, uint deviceIdx, uint packetId, byte[] payload)
    {
        byte[] header = new byte[16];
        Encoding.ASCII.GetBytes(Magic).CopyTo(header, 0);
        BitConverter.GetBytes(deviceIdx).CopyTo(header, 4);
        BitConverter.GetBytes(packetId).CopyTo(header, 8);
        uint len = (payload == null) ? 0 : (uint)payload.Length;
        BitConverter.GetBytes(len).CopyTo(header, 12);
        ns.Write(header, 0, header.Length);
        if (payload != null && payload.Length > 0)
        {
            ns.Write(payload, 0, payload.Length);
        }
    }

    static byte[] RecvPacket(NetworkStream ns, out uint deviceIdx, out uint packetId)
    {
        byte[] header = ReadExact(ns, 16);
        deviceIdx = BitConverter.ToUInt32(header, 4);
        packetId = BitConverter.ToUInt32(header, 8);
        uint size = BitConverter.ToUInt32(header, 12);
        if (size == 0) { return new byte[0]; }
        return ReadExact(ns, (int)size);
    }

    static byte[] ReadExact(NetworkStream ns, int n)
    {
        byte[] buf = new byte[n];
        int read = 0;
        while (read < n)
        {
            int r = ns.Read(buf, read, n - read);
            if (r <= 0) { throw new IOException("Verbindung waehrend des Lesens geschlossen"); }
            read += r;
        }
        return buf;
    }

    static bool DoHandshake(NetworkStream ns)
    {
        SendPacket(ns, 0, PKT_REQUEST_PROTOCOL_VERSION, BitConverter.GetBytes((uint)ClientProtocolVersion));
        uint di, pi;
        byte[] reply = RecvPacket(ns, out di, out pi);
        if (reply.Length < 4) { return false; }
        SendPacket(ns, 0, PKT_SET_CLIENT_NAME, Encoding.ASCII.GetBytes("Claude Signal\0"));
        return true;
    }

    static int ReadString(byte[] buf, int off, out string result)
    {
        ushort len = BitConverter.ToUInt16(buf, off);
        off += 2;
        int strLen = (len > 0) ? (len - 1) : 0; // len zaehlt den Null-Terminator mit
        result = (strLen > 0) ? Encoding.UTF8.GetString(buf, off, strLen) : "";
        off += len;
        return off;
    }

    // ---------------------------------------------------------------
    // Controller-Liste + Zonen holen (byte-genau gegen den laufenden
    // Server verifiziert -- siehe Spec Update 10: 108 LEDs fuer die
    // Turtle Beach Vulcan II via Geraet 0, nicht 109).
    // ---------------------------------------------------------------
    static bool RefreshControllers()
    {
        List<ControllerInfo> fresh = new List<ControllerInfo>();
        try
        {
            using (TcpClient client = new TcpClient())
            {
                client.SendTimeout = SocketTimeoutMs;
                client.ReceiveTimeout = SocketTimeoutMs;
                client.Connect(HostAddr, Port);
                using (NetworkStream ns = client.GetStream())
                {
                    if (!DoHandshake(ns)) { Log("Handshake fehlgeschlagen"); return false; }

                    SendPacket(ns, 0, PKT_REQUEST_CONTROLLER_COUNT, new byte[0]);
                    uint di, pi;
                    byte[] countPayload = RecvPacket(ns, out di, out pi);
                    if (countPayload.Length < 4) { Log("Controller-Zaehler-Antwort zu kurz"); return false; }
                    int count = (int)BitConverter.ToUInt32(countPayload, 0);

                    int limit = allRgbDevices ? count : Math.Min(count, 1);
                    for (int idx = 0; idx < limit; idx++)
                    {
                        SendPacket(ns, (uint)idx, PKT_REQUEST_CONTROLLER_DATA, BitConverter.GetBytes((uint)ClientProtocolVersion));
                        byte[] data = RecvPacket(ns, out di, out pi);
                        ControllerInfo info = ParseControllerData(data, idx);
                        if (info != null && info.TotalLeds > 0) { fresh.Add(info); }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log("RefreshControllers Fehler: " + ex.Message);
            return false;
        }

        if (fresh.Count == 0) { return false; }
        controllers = fresh;
        return true;
    }

    static ControllerInfo ParseControllerData(byte[] buf, int idx)
    {
        try
        {
            int off = 0;
            off += 4; // data_size
            off += 4; // type
            string name; off = ReadString(buf, off, out name);
            string vendor; off = ReadString(buf, off, out vendor); // ab Protokoll >= 1 vorhanden
            string desc; off = ReadString(buf, off, out desc);
            string ver; off = ReadString(buf, off, out ver);
            string serial; off = ReadString(buf, off, out serial);
            string loc; off = ReadString(buf, off, out loc);

            ushort numModes = BitConverter.ToUInt16(buf, off); off += 2;
            off += 4; // active_mode (int32)
            for (int m = 0; m < numModes; m++)
            {
                string mname; off = ReadString(buf, off, out mname);
                off += 4 * 9; // value,flags,speed_min,speed_max,colors_min,colors_max,speed,direction,color_mode
                ushort nc = BitConverter.ToUInt16(buf, off); off += 2;
                off += nc * 4;
            }

            ushort numZones = BitConverter.ToUInt16(buf, off); off += 2;
            List<ZoneInfo> zones = new List<ZoneInfo>();
            for (int z = 0; z < numZones; z++)
            {
                string zname; off = ReadString(buf, off, out zname);
                off += 4; // zone type
                off += 4; // leds_min
                off += 4; // leds_max
                uint ledsCount = BitConverter.ToUInt32(buf, off); off += 4;
                ushort matrixLen = BitConverter.ToUInt16(buf, off); off += 2;
                off += matrixLen;
                ZoneInfo zi = new ZoneInfo();
                zi.Index = z;
                zi.LedCount = (int)ledsCount;
                zones.Add(zi);
            }

            ushort numLeds = BitConverter.ToUInt16(buf, off); off += 2;

            ControllerInfo ci = new ControllerInfo();
            ci.Index = idx;
            ci.TotalLeds = numLeds;
            ci.Zones = zones;
            Log("Geraet " + idx + " (" + name + "): " + numLeds + " LEDs, " + zones.Count + " Zone(n)");
            return ci;
        }
        catch (Exception ex)
        {
            Log("ParseControllerData Fehler (Geraet " + idx + "): " + ex.Message);
            return null;
        }
    }

    static void EnsureDirectMode()
    {
        for (int i = 0; i < controllers.Count; i++)
        {
            ControllerInfo c = controllers[i];
            try
            {
                using (TcpClient client = new TcpClient())
                {
                    client.SendTimeout = SocketTimeoutMs;
                    client.ReceiveTimeout = SocketTimeoutMs;
                    client.Connect(HostAddr, Port);
                    using (NetworkStream ns = client.GetStream())
                    {
                        if (DoHandshake(ns))
                        {
                            SendPacket(ns, (uint)c.Index, PKT_RGBCONTROLLER_SETCUSTOMMODE, new byte[0]);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Log("EnsureDirectMode Fehler (Geraet " + c.Index + "): " + ex.Message);
            }
        }
    }

    // Ein Update-Paket = eine frische, kurzlebige Verbindung (siehe Kommentar
    // am Dateikopf -- eine dauerhafte Verbindung wird vom Server nach 1-2
    // Paketen sauber geschlossen).
    static bool SendZoneUpdate(int deviceIdx, int zoneIdx, int ledCount, byte[] colorBytes)
    {
        try
        {
            using (TcpClient client = new TcpClient())
            {
                client.SendTimeout = SocketTimeoutMs;
                client.ReceiveTimeout = SocketTimeoutMs;
                client.Connect(HostAddr, Port);
                using (NetworkStream ns = client.GetStream())
                {
                    if (!DoHandshake(ns)) { return false; }

                    byte[] inner = new byte[4 + 2 + colorBytes.Length];
                    BitConverter.GetBytes((uint)zoneIdx).CopyTo(inner, 0);
                    BitConverter.GetBytes((ushort)ledCount).CopyTo(inner, 4);
                    colorBytes.CopyTo(inner, 6);

                    byte[] payload = new byte[4 + inner.Length];
                    BitConverter.GetBytes((uint)inner.Length).CopyTo(payload, 0);
                    inner.CopyTo(payload, 4);

                    SendPacket(ns, (uint)deviceIdx, PKT_RGBCONTROLLER_UPDATEZONELEDS, payload);
                }
            }
            return true;
        }
        catch (Exception ex)
        {
            Log("SendZoneUpdate Fehler (Geraet " + deviceIdx + " Zone " + zoneIdx + "): " + ex.Message);
            return false;
        }
    }

    // ---------------------------------------------------------------
    // Animationen: liefert fuer n LEDs ein Byte-Array (R,G,B,0 je LED).
    // ---------------------------------------------------------------
    static byte[] BuildFrame(string state, long t, int n)
    {
        byte[] result = new byte[Math.Max(0, n) * 4];
        if (n <= 0) { return result; }

        if (state == "green")
        {
            FillSolid(result, n, 0x00, 0xB0, 0x00);
        }
        else if (state == "red")
        {
            double phase = (t / 1400.0) % 1.0;
            double breath = 0.75 + 0.25 * Math.Sin(t / 900.0);
            for (int i = 0; i < n; i++)
            {
                double p = (double)i / n;
                double d = WrappedDistance(p, phase);
                double intensity = FalloffIntensity(d, 0.35) * breath;
                byte r, g, b;
                LerpColor(0x06, 0x1C, 0x6E, 0x28, 0x78, 0xFF, intensity, out r, out g, out b);
                SetLed(result, i, r, g, b);
            }
        }
        else if (state == "yellow")
        {
            double k = 0.5 + 0.5 * Math.Sin(t / 127.0);
            byte r, g, b;
            LerpColor(0x3C, 0x00, 0x00, 0xE5, 0x39, 0x35, k, out r, out g, out b);
            FillSolid(result, n, r, g, b);
        }
        else if (state == "yellowbusy")
        {
            double phase = (t / 1000.0) % 1.0;
            for (int i = 0; i < n; i++)
            {
                double p = (double)i / n;
                double d = WrappedDistance(p, phase);
                double intensity = FalloffIntensity(d, 0.35);
                byte r, g, b;
                LerpColor(0x28, 0x00, 0x00, 0xFF, 0x10, 0x10, intensity, out r, out g, out b);
                SetLed(result, i, r, g, b);
            }
        }
        else // "gray" oder unbekannt/stale
        {
            FillSolid(result, n, 0x10, 0x50, 0xE0);
        }

        return result;
    }

    static double WrappedDistance(double a, double b)
    {
        double d = Math.Abs(a - b);
        if (d > 0.5) { d = 1.0 - d; }
        return d;
    }

    static double FalloffIntensity(double d, double width)
    {
        double tn = d / width;
        if (tn >= 1.0) { return 0.0; }
        if (tn < 0.0) { tn = 0.0; }
        return Math.Cos(tn * (Math.PI / 2.0));
    }

    static void LerpColor(byte r0, byte g0, byte b0, byte r1, byte g1, byte b1, double t, out byte r, out byte g, out byte b)
    {
        if (t < 0.0) { t = 0.0; }
        if (t > 1.0) { t = 1.0; }
        r = (byte)(r0 + (r1 - r0) * t);
        g = (byte)(g0 + (g1 - g0) * t);
        b = (byte)(b0 + (b1 - b0) * t);
    }

    static void SetLed(byte[] buf, int i, byte r, byte g, byte b)
    {
        int off = i * 4;
        buf[off] = r; buf[off + 1] = g; buf[off + 2] = b; buf[off + 3] = 0;
    }

    static void FillSolid(byte[] buf, int n, byte r, byte g, byte b)
    {
        for (int i = 0; i < n; i++) { SetLed(buf, i, r, g, b); }
    }
}
