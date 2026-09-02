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
// Fix: fuer JEDES Update-Paket (pro Controller, pro Frame) eine frische,
// kurzlebige TCP-Verbindung oeffnen -> senden -> schliessen.
//
// Haertung nach Review (siehe Update 11 im Spec-Dokument):
// - EIN Paket pro Controller pro Frame (1050 UPDATELEDS) statt einem pro
//   Zone -- weniger Verbindungen, einfacher, und I2-Bug (data_size zaehlte
//   sich nicht selbst mit) automatisch mitbehoben.
// - Byte-identische Frames werden uebersprungen (nur 1x/s Keepalive), damit
//   ein Leerlauf-Zustand (grau/gruen) nicht unnoetig viele Verbindungen pro
//   Sekunde erzeugt (Port-Erschoepfungsrisiko bei vielen Controllern).
// - Bild-Frequenz wird an die Zahl der Controller gekoppelt gedeckelt
//   (Controller * FPS <= 40), damit auch der Animations-Fall (rot/gelb) bei
//   AllRgbDevices mit vielen Geraeten nicht zu viele Verbindungen/Sekunde
//   erzeugt.
//
// v6 (siehe Update 12 im Spec-Dokument): Farben/Effekte pro Zustand sind ueber
// config.json konfigurierbar (Block "States"). Jedes Feld ist optional und wird
// einzeln validiert -- ein ungueltiger Zustand faellt NUR fuer sich selbst auf
// den eingebauten Standard zurueck (der exakt dem bisherigen festverdrahteten
// Verhalten entspricht), der Rest der Konfiguration bleibt wirksam. Aenderungen
// an config.json werden alle ~5 s automatisch neu eingelesen (Live-Reload).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

class SignalAnimator
{
    // --- OpenRGB SDK-Protokoll ---
    const string HostAddr = "127.0.0.1";
    const int Port = 6742;
    const int ClientProtocolVersion = 1; // haelt das Controller-Data-Layout einfach (keine Brightness-Felder)

    const uint PKT_REQUEST_CONTROLLER_COUNT = 0;
    const uint PKT_REQUEST_CONTROLLER_DATA = 1;
    const uint PKT_REQUEST_PROTOCOL_VERSION = 40;
    const uint PKT_SET_CLIENT_NAME = 50;
    const uint PKT_RGBCONTROLLER_UPDATELEDS = 1050;
    const uint PKT_RGBCONTROLLER_SETCUSTOMMODE = 1100;

    const int MaxReplySize = 4 * 1024 * 1024; // I9: Wire-Laengen deckeln
    const int StaleMs = 10000;
    const int SocketTimeoutMs = 2000;
    const int KeepaliveMs = 1000;               // C1b: unveraenderte Frames trotzdem 1x/s senden
    const int IdleExitMs = 600000;               // I6: 10 Minuten durchgehend grau -> beenden
    const int HeartbeatMs = 30000;               // I4: Herzschlag nur alle ~30 s
    const int MaxLogLines = 200;                 // I4: Log-Datei bleibt begrenzt
    const int ConfigCheckMs = 5000;              // v6: Live-Reload-Intervall

    static Mutex mutex;
    static string baseDir;
    static string stateFile;
    static string configFile;
    static string logFile;
    static bool allRgbDevices = false;

    static List<string> logLines = new List<string>();
    static string lastLoggedState = "";
    static string lastKnownState = "gray";
    static long lastGoodEpochMs = 0;   // I11: gegen "haengt in alter Farbe fest"
    static long frameCount = 0;
    static long lastHeartbeatMs = 0;
    static long grayStartMs = -1;      // I6: seit wann durchgehend grau
    static int frameIntervalMs = 50;   // C1c: dynamisch an Controller-Zahl gekoppelt
    static Stopwatch clock;            // M4: monotone Animations-Uhr

    static long lastConfigCheckMs = 0;             // v6: Live-Reload
    static DateTime configLastWrite = DateTime.MinValue;
    static bool forceReconnect = false;            // v6: AllRgbDevices geaendert -> Geraete neu abfragen

    class ControllerInfo
    {
        public int Index;
        public int TotalLeds;
        public byte[] LastSentFrame;
        public long LastSentMs;
    }

    // v6: Aufgeloeste Zustands-Konfiguration -- pro internem Zustand einmal beim
    // (Neu-)Laden berechnet, nicht bei jedem Frame neu geparst.
    class StateConfig
    {
        public string Effect;    // "solid" | "pulse" | "wave"
        public byte FromR, FromG, FromB;
        public byte ToR, ToG, ToB;
        public int PeriodMs;
        public bool Breath;
    }

    static List<ControllerInfo> controllers = new List<ControllerInfo>();
    static Dictionary<string, StateConfig> stateConfigs = new Dictionary<string, StateConfig>();

    static int Main()
    {
        bool acquired = false;
        try
        {
            mutex = new Mutex(false, "Local\\ClaudeSignalAnimatorSingleton");
            try
            {
                acquired = mutex.WaitOne(0);
            }
            catch (AbandonedMutexException)
            {
                // Vorheriger Besitzer ist abgestuerzt -- der Wait hat den Mutex trotzdem uebernommen.
                acquired = true;
            }
        }
        catch
        {
            return 0;
        }

        if (!acquired) { return 0; }

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

        LoadExistingLog();
        Log("SignalAnimator gestartet");

        ReadConfig();
        try { configLastWrite = File.Exists(configFile) ? File.GetLastWriteTimeUtc(configFile) : DateTime.MinValue; }
        catch { configLastWrite = DateTime.MinValue; }
        Log("Konfiguration: AllRgbDevices=" + allRgbDevices);

        clock = Stopwatch.StartNew();
        bool haveControllers = false;

        while (true)
        {
            if (NowMs() - lastConfigCheckMs >= ConfigCheckMs)
            {
                lastConfigCheckMs = NowMs();
                CheckConfigReload();
                if (forceReconnect)
                {
                    forceReconnect = false;
                    haveControllers = false; // v6: AllRgbDevices geaendert -> Geraete neu abfragen
                }
            }

            if (!haveControllers)
            {
                haveControllers = RefreshControllers();
                if (haveControllers)
                {
                    EnsureDirectMode();
                    RecomputeFrameInterval();
                    Log("Verbunden: " + controllers.Count + " Controller, " + TotalLedsSummary() +
                        ", Frameintervall=" + frameIntervalMs + " ms");
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

                // I6: nach 10 Minuten durchgehend Grau selbst beenden -- die
                // Tick-Ueberwachung im Overlay (alle ~10 s) startet bei Bedarf neu.
                if (state == "gray")
                {
                    if (grayStartMs < 0) { grayStartMs = NowMs(); }
                    else if (NowMs() - grayStartMs >= IdleExitMs)
                    {
                        Log("Leerlauf-Ende: " + (IdleExitMs / 1000) + " s durchgehend grau -- beende mich");
                        return;
                    }
                }
                else
                {
                    grayStartMs = -1;
                }

                long t = clock.ElapsedMilliseconds;
                bool allOk = true;

                for (int ci = 0; ci < controllers.Count; ci++)
                {
                    ControllerInfo c = controllers[ci];
                    byte[] frame = BuildFrame(state, t, c.TotalLeds);
                    bool sameAsLast = FramesEqual(frame, c.LastSentFrame);
                    bool keepaliveDue = (NowMs() - c.LastSentMs) >= KeepaliveMs;
                    if (sameAsLast && !keepaliveDue)
                    {
                        continue; // C1b: unveraendertes Bild -- keine Verbindung noetig
                    }
                    bool ok = SendControllerUpdate(c.Index, c.TotalLeds, frame);
                    if (ok)
                    {
                        c.LastSentFrame = frame;
                        c.LastSentMs = NowMs();
                    }
                    else
                    {
                        allOk = false;
                    }
                }

                if (!allOk)
                {
                    haveControllers = false;
                    Log("Verbindung verloren -- naechster Zyklus versucht Neuverbindung");
                }

                frameCount++;
                if (NowMs() - lastHeartbeatMs >= HeartbeatMs)
                {
                    lastHeartbeatMs = NowMs();
                    Log("Herzschlag: zustand=" + state + " frames=" + frameCount + " frameIntervalMs=" + frameIntervalMs);
                }
            }
            catch (Exception ex)
            {
                Log("Fehler in der Hauptschleife: " + ex.Message);
                haveControllers = false;
            }

            Thread.Sleep(frameIntervalMs);
        }
    }

    // ---------------------------------------------------------------
    // Logging: bei jedem nennenswerten Ereignis (nicht bei jedem Frame)
    // wird die GESAMTE Log-Datei neu geschrieben, begrenzt auf die letzten
    // ~200 Zeilen. Beim Start wird die bestehende Datei fortgesetzt
    // (getrimmt), nicht geloescht -- sonst verliert man den Verlauf vor
    // einem Absturz/Neustart genau dann, wenn man ihn braeuchte.
    // ---------------------------------------------------------------
    static void LoadExistingLog()
    {
        logLines = new List<string>();
        try
        {
            if (File.Exists(logFile))
            {
                string[] existing = File.ReadAllLines(logFile);
                int start = Math.Max(0, existing.Length - MaxLogLines);
                for (int i = start; i < existing.Length; i++) { logLines.Add(existing[i]); }
            }
        }
        catch { }
    }

    static void Log(string msg)
    {
        try
        {
            string line = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss") + "Z " + msg;
            logLines.Add(line);
            while (logLines.Count > MaxLogLines) { logLines.RemoveAt(0); }
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

    // C1c: Bildrate an die Zahl der aktiven Controller koppeln, damit die
    // gesamte Verbindungsrate (Controller * FPS) 40/s nicht uebersteigt --
    // auch wenn jeder Frame tatsaechlich neu ist (Animationszustand).
    static void RecomputeFrameInterval()
    {
        int n = Math.Max(1, controllers.Count);
        double fps = 40.0 / n;
        if (fps > 20.0) { fps = 20.0; }
        if (fps < 1.0) { fps = 1.0; }
        frameIntervalMs = (int)Math.Round(1000.0 / fps);
    }

    static bool FramesEqual(byte[] a, byte[] b)
    {
        if (a == null || b == null) { return false; }
        if (a.Length != b.Length) { return false; }
        for (int i = 0; i < a.Length; i++) { if (a[i] != b[i]) { return false; } }
        return true;
    }

    // ---------------------------------------------------------------
    // v6: Live-Reload -- alle ~5 s prueft die Hauptschleife, ob sich
    // config.json seit dem letzten Einlesen geaendert hat.
    // ---------------------------------------------------------------
    static void CheckConfigReload()
    {
        try
        {
            DateTime lw = File.Exists(configFile) ? File.GetLastWriteTimeUtc(configFile) : DateTime.MinValue;
            if (lw == configLastWrite) { return; }
            configLastWrite = lw;
            bool wasAllRgb = allRgbDevices;
            ReadConfig();
            Log("Konfiguration neu geladen");
            if (allRgbDevices != wasAllRgb) { forceReconnect = true; }
        }
        catch { }
    }

    // ---------------------------------------------------------------
    // config.json: AllRgbDevices (bool) + optionaler "States"-Block mit
    // Farben/Effekten pro Zustand. Jedes Feld ist einzeln optional/defensiv:
    // ein ungueltiger Zustand faellt NUR fuer sich selbst auf den
    // eingebauten Standard zurueck (siehe DefaultFor). Komplett fehlende
    // oder unlesbare Datei -> alle Standardwerte, kein Fehler.
    // ---------------------------------------------------------------
    static readonly string[] StateKeys = new string[] { "working", "waiting", "waitingbusy", "done", "idle" };

    static void ReadConfig()
    {
        allRgbDevices = false;
        stateConfigs = new Dictionary<string, StateConfig>();
        for (int i = 0; i < StateKeys.Length; i++) { stateConfigs[StateKeys[i]] = DefaultFor(StateKeys[i]); }

        try
        {
            if (!File.Exists(configFile)) { return; }
            string content = File.ReadAllText(configFile);
            if (content.Trim().Length == 0) { return; }

            JavaScriptSerializer js = new JavaScriptSerializer();
            object parsed = js.DeserializeObject(content);
            Dictionary<string, object> root = parsed as Dictionary<string, object>;
            if (root == null) { return; }

            object allRgbObj;
            if (root.TryGetValue("AllRgbDevices", out allRgbObj) && allRgbObj is bool)
            {
                allRgbDevices = (bool)allRgbObj;
            }

            object statesObj;
            if (root.TryGetValue("States", out statesObj))
            {
                Dictionary<string, object> states = statesObj as Dictionary<string, object>;
                if (states != null)
                {
                    for (int i = 0; i < StateKeys.Length; i++)
                    {
                        string key = StateKeys[i];
                        object entryObj;
                        if (!states.TryGetValue(key, out entryObj)) { continue; }
                        Dictionary<string, object> entry = entryObj as Dictionary<string, object>;
                        if (entry == null)
                        {
                            Log("Konfiguration: Zustand '" + key + "' ungueltig -- Standard verwendet");
                            continue;
                        }
                        StateConfig parsedCfg;
                        if (TryParseStateConfig(entry, out parsedCfg))
                        {
                            stateConfigs[key] = parsedCfg;
                        }
                        else
                        {
                            Log("Konfiguration: Zustand '" + key + "' ungueltig -- Standard verwendet");
                        }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log("config.json nicht lesbar/ungueltig: " + ex.Message + " -- Standardwerte verwendet");
            stateConfigs = new Dictionary<string, StateConfig>();
            for (int i = 0; i < StateKeys.Length; i++) { stateConfigs[StateKeys[i]] = DefaultFor(StateKeys[i]); }
        }
    }

    // Eingebaute Standardwerte -- entsprechen exakt dem Verhalten vor v6.
    static StateConfig DefaultFor(string key)
    {
        StateConfig c = new StateConfig();
        if (key == "working")
        {
            c.Effect = "wave";
            c.FromR = 0x06; c.FromG = 0x1C; c.FromB = 0x6E;
            c.ToR = 0x28; c.ToG = 0x78; c.ToB = 0xFF;
            c.PeriodMs = 1400;
            c.Breath = true;
        }
        else if (key == "waiting")
        {
            c.Effect = "pulse";
            c.FromR = 0x3C; c.FromG = 0x00; c.FromB = 0x00;
            c.ToR = 0xFF; c.ToG = 0x00; c.ToB = 0x00;
            c.PeriodMs = 800;
            c.Breath = false;
        }
        else if (key == "waitingbusy")
        {
            c.Effect = "pulse";
            c.FromR = 0x3C; c.FromG = 0x00; c.FromB = 0x00;
            c.ToR = 0xFF; c.ToG = 0x00; c.ToB = 0x00;
            c.PeriodMs = 400;
            c.Breath = false;
        }
        else if (key == "done")
        {
            c.Effect = "solid";
            c.ToR = 0x00; c.ToG = 0xB0; c.ToB = 0x00;
            c.FromR = c.ToR; c.FromG = c.ToG; c.FromB = c.ToB;
            c.PeriodMs = 1000;
            c.Breath = false;
        }
        else // "idle" (und jeder unbekannte/verfallene Zustand)
        {
            c.Effect = "solid";
            c.ToR = 0x10; c.ToG = 0x50; c.ToB = 0xE0;
            c.FromR = c.ToR; c.FromG = c.ToG; c.FromB = c.ToB;
            c.PeriodMs = 1000;
            c.Breath = false;
        }
        return c;
    }

    static string ConfigKeyForInternalState(string internalState)
    {
        if (internalState == "red") { return "working"; }
        if (internalState == "yellow") { return "waiting"; }
        if (internalState == "yellowbusy") { return "waitingbusy"; }
        if (internalState == "green") { return "done"; }
        return "idle"; // "gray" oder unbekannt/stale
    }

    static bool TryParseStateConfig(Dictionary<string, object> entry, out StateConfig cfg)
    {
        cfg = null;
        object effectObj;
        if (!entry.TryGetValue("effect", out effectObj)) { return false; }
        string effect = effectObj as string;
        if (effect == null) { return false; }
        effect = effect.Trim().ToLowerInvariant();
        if (effect != "solid" && effect != "pulse" && effect != "wave") { return false; }

        StateConfig c = new StateConfig();
        c.Effect = effect;

        if (effect == "solid")
        {
            object colorObj;
            byte r, g, b;
            if (!entry.TryGetValue("color", out colorObj)) { return false; }
            string colorStr = colorObj as string;
            if (colorStr == null || !TryParseHexColor(colorStr, out r, out g, out b)) { return false; }
            c.ToR = r; c.ToG = g; c.ToB = b;
            c.FromR = r; c.FromG = g; c.FromB = b;
            c.PeriodMs = 1000;
            c.Breath = false;
            cfg = c;
            return true;
        }

        // pulse/wave: from, to (Pflicht), period_ms + breath (optional)
        object fromObj, toObj, periodObj, breathObj;
        byte fr, fg, fb, tr, tg, tb;
        if (!entry.TryGetValue("from", out fromObj)) { return false; }
        if (!entry.TryGetValue("to", out toObj)) { return false; }
        string fromStr = fromObj as string;
        string toStr = toObj as string;
        if (fromStr == null || toStr == null) { return false; }
        if (!TryParseHexColor(fromStr, out fr, out fg, out fb)) { return false; }
        if (!TryParseHexColor(toStr, out tr, out tg, out tb)) { return false; }

        int periodMs = 1000;
        if (entry.TryGetValue("period_ms", out periodObj))
        {
            if (!TryToInt(periodObj, out periodMs)) { return false; }
        }
        if (periodMs < 50 || periodMs > 60000) { return false; } // Plausibilitaetsgrenzen

        bool breath = false;
        if (entry.TryGetValue("breath", out breathObj) && breathObj is bool) { breath = (bool)breathObj; }

        c.FromR = fr; c.FromG = fg; c.FromB = fb;
        c.ToR = tr; c.ToG = tg; c.ToB = tb;
        c.PeriodMs = periodMs;
        c.Breath = breath;
        cfg = c;
        return true;
    }

    // Akzeptiert "#RRGGBB" und "RRGGBB".
    static bool TryParseHexColor(string s, out byte r, out byte g, out byte b)
    {
        r = 0; g = 0; b = 0;
        if (s == null) { return false; }
        s = s.Trim();
        if (s.Length > 0 && s[0] == '#') { s = s.Substring(1); }
        if (s.Length != 6) { return false; }
        int rv, gv, bv;
        if (!int.TryParse(s.Substring(0, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out rv)) { return false; }
        if (!int.TryParse(s.Substring(2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out gv)) { return false; }
        if (!int.TryParse(s.Substring(4, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out bv)) { return false; }
        r = (byte)rv; g = (byte)gv; b = (byte)bv;
        return true;
    }

    static bool TryToInt(object o, out int result)
    {
        result = 0;
        if (o is int) { result = (int)o; return true; }
        if (o is double) { result = (int)(double)o; return true; }
        if (o is long) { result = (int)(long)o; return true; }
        string s = o as string;
        if (s != null) { return int.TryParse(s, out result); }
        return false;
    }

    // ---------------------------------------------------------------
    // state.txt: Format "<zustand> <epochMs>". FileShare.ReadWrite|Delete,
    // damit das atomare Move-Item-Rename des Overlays nicht gelegentlich an
    // einer offenen Lesehandle scheitert (I3). Sharing-Konflikte werden
    // toleriert (kurzer Retry). I11: haengt das Lesen laenger als StaleMs
    // fest (aus welchem Grund auch immer), faellt der Zustand auf "gray"
    // zurueck, statt für immer die letzte Farbe zu zeigen.
    // ---------------------------------------------------------------
    static string ReadState()
    {
        string content = null;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                if (!File.Exists(stateFile)) { return StaleFallback(); }
                using (FileStream fs = new FileStream(stateFile, FileMode.Open, FileAccess.Read,
                                                        FileShare.ReadWrite | FileShare.Delete))
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

        if (content == null) { return StaleFallback(); }

        content = content.Trim();
        string[] parts = content.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) { return StaleFallback(); }

        long epochMs;
        if (!long.TryParse(parts[1], out epochMs)) { return StaleFallback(); }

        if (NowMs() - epochMs > StaleMs) { return "gray"; }

        lastKnownState = parts[0];
        lastGoodEpochMs = epochMs;
        return lastKnownState;
    }

    static string StaleFallback()
    {
        if (NowMs() - lastGoodEpochMs > StaleMs) { return "gray"; }
        return lastKnownState;
    }

    // ---------------------------------------------------------------
    // Netzwerk-Grundfunktionen
    // ---------------------------------------------------------------
    static TcpClient OpenConnection()
    {
        TcpClient client = new TcpClient();
        client.NoDelay = true; // M7: kein Nagle-Delay fuer unsere kleinen Pakete
        client.SendTimeout = SocketTimeoutMs;
        client.ReceiveTimeout = SocketTimeoutMs;
        ConnectWithTimeout(client, SocketTimeoutMs);
        return client;
    }

    // M3: Verbindungsaufbau mit echtem Timeout statt blockierendem Connect().
    static void ConnectWithTimeout(TcpClient client, int timeoutMs)
    {
        IAsyncResult ar = client.BeginConnect(HostAddr, Port, null, null);
        bool ok = ar.AsyncWaitHandle.WaitOne(timeoutMs);
        if (!ok)
        {
            try { client.Close(); } catch { }
            throw new IOException("Verbindungsaufbau-Timeout nach " + timeoutMs + " ms");
        }
        client.EndConnect(ar); // wirft, falls der Connect selbst fehlgeschlagen ist
    }

    // M7: Header+Payload in einem Write.
    static void SendPacket(NetworkStream ns, uint deviceIdx, uint packetId, byte[] payload)
    {
        int payloadLen = (payload == null) ? 0 : payload.Length;
        byte[] full = new byte[16 + payloadLen];
        full[0] = (byte)'O'; full[1] = (byte)'R'; full[2] = (byte)'G'; full[3] = (byte)'B';
        BitConverter.GetBytes(deviceIdx).CopyTo(full, 4);
        BitConverter.GetBytes(packetId).CopyTo(full, 8);
        BitConverter.GetBytes((uint)payloadLen).CopyTo(full, 12);
        if (payloadLen > 0) { Array.Copy(payload, 0, full, 16, payloadLen); }
        ns.Write(full, 0, full.Length);
    }

    // M2: Magic-Praefix verifizieren. I9: Antwortgroesse deckeln.
    static byte[] RecvPacket(NetworkStream ns, out uint deviceIdx, out uint packetId)
    {
        byte[] header = ReadExact(ns, 16);
        if (header[0] != (byte)'O' || header[1] != (byte)'R' || header[2] != (byte)'G' || header[3] != (byte)'B')
        {
            throw new IOException("Ungueltiges Magic-Praefix im Antwort-Header");
        }
        deviceIdx = BitConverter.ToUInt32(header, 4);
        packetId = BitConverter.ToUInt32(header, 8);
        uint size = BitConverter.ToUInt32(header, 12);
        if (size > MaxReplySize) { throw new IOException("Antwortgroesse zu gross: " + size + " Byte"); }
        if (size == 0) { return new byte[0]; }
        return ReadExact(ns, (int)size);
    }

    // M1: fremde/unaufgeforderte Pakete (z. B. DEVICE_LIST_UPDATED=100)
    // ueberspringen, bis das erwartete Paket kommt (oder aufgeben).
    static byte[] RecvExpected(NetworkStream ns, uint expectedPacketId)
    {
        for (int attempts = 0; attempts < 8; attempts++)
        {
            uint di, pi;
            byte[] payload = RecvPacket(ns, out di, out pi);
            if (pi == expectedPacketId) { return payload; }
        }
        throw new IOException("Erwartetes Paket " + expectedPacketId + " nicht erhalten (zu viele fremde Pakete)");
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
        byte[] reply = RecvExpected(ns, PKT_REQUEST_PROTOCOL_VERSION);
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
    // Controller-Liste holen (byte-genau gegen den laufenden Server
    // verifiziert -- siehe Spec Update 10: 108 LEDs fuer die Turtle Beach
    // Vulcan II via Geraet 0, nicht 109). Zonen werden nur noch ueberlaufen
    // (fuer den korrekten Offset bis num_leds), nicht mehr gespeichert --
    // seit C1a wird pro Controller in einem Stueck aktualisiert (1050),
    // nicht mehr pro Zone (1051).
    // ---------------------------------------------------------------
    static bool RefreshControllers()
    {
        List<ControllerInfo> fresh = new List<ControllerInfo>();
        try
        {
            using (TcpClient client = OpenConnection())
            using (NetworkStream ns = client.GetStream())
            {
                if (!DoHandshake(ns)) { Log("Handshake fehlgeschlagen"); return false; }

                SendPacket(ns, 0, PKT_REQUEST_CONTROLLER_COUNT, new byte[0]);
                byte[] countPayload = RecvExpected(ns, PKT_REQUEST_CONTROLLER_COUNT);
                if (countPayload.Length < 4) { Log("Controller-Zaehler-Antwort zu kurz"); return false; }
                int count = (int)BitConverter.ToUInt32(countPayload, 0);

                int limit = allRgbDevices ? count : Math.Min(count, 1);
                for (int idx = 0; idx < limit; idx++)
                {
                    SendPacket(ns, (uint)idx, PKT_REQUEST_CONTROLLER_DATA, BitConverter.GetBytes((uint)ClientProtocolVersion));
                    byte[] data = RecvExpected(ns, PKT_REQUEST_CONTROLLER_DATA);
                    ControllerInfo info = ParseControllerData(data, idx);
                    if (info != null && info.TotalLeds > 0) { fresh.Add(info); }
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
            for (int z = 0; z < numZones; z++)
            {
                string zname; off = ReadString(buf, off, out zname);
                off += 4; // zone type
                off += 4; // leds_min
                off += 4; // leds_max
                off += 4; // leds_count
                ushort matrixLen = BitConverter.ToUInt16(buf, off); off += 2;
                off += matrixLen;
            }

            ushort numLeds = BitConverter.ToUInt16(buf, off); off += 2;

            ControllerInfo ci = new ControllerInfo();
            ci.Index = idx;
            ci.TotalLeds = numLeds;
            ci.LastSentFrame = null;
            ci.LastSentMs = 0;
            Log("Geraet " + idx + " (" + name + "): " + numLeds + " LEDs");
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
                using (TcpClient client = OpenConnection())
                using (NetworkStream ns = client.GetStream())
                {
                    if (DoHandshake(ns))
                    {
                        SendPacket(ns, (uint)c.Index, PKT_RGBCONTROLLER_SETCUSTOMMODE, new byte[0]);
                    }
                }
            }
            catch (Exception ex)
            {
                Log("EnsureDirectMode Fehler (Geraet " + c.Index + "): " + ex.Message);
            }
        }
    }

    // C1a: EIN Paket pro Controller pro Frame (1050 UPDATELEDS) statt einem
    // pro Zone -- weniger Verbindungen, einfacherer Code. Jedes Update-Paket
    // bekommt eine frische, kurzlebige Verbindung (siehe Kommentar am
    // Dateikopf -- eine dauerhafte Verbindung wird vom Server nach 1-2
    // Paketen sauber geschlossen).
    static bool SendControllerUpdate(int deviceIdx, int ledCount, byte[] colorBytes)
    {
        try
        {
            using (TcpClient client = OpenConnection())
            using (NetworkStream ns = client.GetStream())
            {
                if (!DoHandshake(ns)) { return false; }

                byte[] inner = new byte[2 + colorBytes.Length];
                BitConverter.GetBytes((ushort)ledCount).CopyTo(inner, 0);
                colorBytes.CopyTo(inner, 2);

                byte[] payload = new byte[4 + inner.Length];
                // I2: data_size zaehlt sich selbst mit (4 Byte Feld + Rest).
                BitConverter.GetBytes((uint)(4 + inner.Length)).CopyTo(payload, 0);
                inner.CopyTo(payload, 4);

                SendPacket(ns, (uint)deviceIdx, PKT_RGBCONTROLLER_UPDATELEDS, payload);
            }
            return true;
        }
        catch (Exception ex)
        {
            Log("SendControllerUpdate Fehler (Geraet " + deviceIdx + "): " + ex.Message);
            return false;
        }
    }

    // ---------------------------------------------------------------
    // Animationen: liefert fuer n LEDs ein Byte-Array (R,G,B,0 je LED).
    // Zustands-Farben/Effekte kommen aus stateConfigs (v6, config.json)
    // -- ohne Konfiguration entsprechen sie exakt dem alten festverdrahteten
    // Verhalten (siehe DefaultFor oben).
    // ---------------------------------------------------------------
    static byte[] BuildFrame(string state, long t, int n)
    {
        byte[] result = new byte[Math.Max(0, n) * 4];
        if (n <= 0) { return result; }

        string key = ConfigKeyForInternalState(state);
        StateConfig cfg;
        if (!stateConfigs.TryGetValue(key, out cfg) || cfg == null) { cfg = DefaultFor(key); }

        if (cfg.Effect == "pulse")
        {
            double k = 0.5 + 0.5 * Math.Sin(t * 2.0 * Math.PI / cfg.PeriodMs);
            byte r, g, b;
            LerpColor(cfg.FromR, cfg.FromG, cfg.FromB, cfg.ToR, cfg.ToG, cfg.ToB, k, out r, out g, out b);
            FillSolid(result, n, r, g, b);
        }
        else if (cfg.Effect == "wave")
        {
            double phase = (t / (double)cfg.PeriodMs) % 1.0;
            double breath = cfg.Breath ? (0.75 + 0.25 * Math.Sin(t / 900.0)) : 1.0;
            for (int i = 0; i < n; i++)
            {
                double p = (double)i / n;
                double d = WrappedDistance(p, phase);
                double intensity = FalloffIntensity(d, 0.35) * breath;
                byte r, g, b;
                LerpColor(cfg.FromR, cfg.FromG, cfg.FromB, cfg.ToR, cfg.ToG, cfg.ToB, intensity, out r, out g, out b);
                SetLed(result, i, r, g, b);
            }
        }
        else // "solid" (auch Fallback bei unbekanntem Effect-Wert, sollte durch Validierung nie vorkommen)
        {
            FillSolid(result, n, cfg.ToR, cfg.ToG, cfg.ToB);
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
