// PC Health Check - WPF front end for PCHealthCheck.ps1.
// Written for the C# 5 compiler that ships with .NET Framework 4.8 (see build.ps1), so no
// string interpolation, null-conditionals or expression-bodied members.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

[assembly: AssemblyTitle("PC Health Check")]
[assembly: AssemblyProduct("PC Health Check")]
[assembly: AssemblyDescription("Runs common Windows diagnostics and explains the results in plain English.")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName = ".NET Framework 4.8")]

namespace PCHealthCheck
{
    class CheckResult
    {
        public string Category, Name, Status, Summary, Details, Advice;
        public List<QuickFix> Fixes = new List<QuickFix>();
    }

    // "open" fixes open a settings page, tool or website. "run" fixes run a PowerShell command in a
    // visible window after the user confirms; Admin ones ask Windows for elevation.
    class QuickFix
    {
        public string Kind, Label, Target, Arguments, Command, Explain;
        public bool Admin;
    }

    class StatusStyle
    {
        public readonly Color Color;
        public readonly string Glyph, Label;

        public StatusStyle(string hex, string glyph, string label)
        {
            Color = (Color)ColorConverter.ConvertFromString(hex);
            Glyph = glyph;
            Label = label;
        }
    }

    public static class Program
    {
        [STAThread]
        public static void Main(string[] args)
        {
            bool deep = args.Any(a => a.Equals("--deep", StringComparison.OrdinalIgnoreCase));
            // --screenshot <file.png> [--show-fix-dialog]: render the window to an image after the scan and exit
            // (for documentation and testing; works even when the screen is locked).
            int shot = Array.FindIndex(args, a => a.Equals("--screenshot", StringComparison.OrdinalIgnoreCase));
            var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
            var ui = new MainUi(deep);
            if (shot >= 0 && shot + 1 < args.Length)
            {
                ui.SnapshotPath = System.IO.Path.GetFullPath(args[shot + 1]);
                ui.SnapshotDialog = args.Any(a => a.Equals("--show-fix-dialog", StringComparison.OrdinalIgnoreCase));
            }
            app.Run(ui.Window);
        }
    }

    class MainUi
    {
        const int StandardCheckCount = 26;
        const int DeepCheckCount = 30;

        static readonly Dictionary<string, StatusStyle> Styles = new Dictionary<string, StatusStyle>
        {
            { "Problem", new StatusStyle("#FF6B6B", "", "Needs attention") },
            { "Warning", new StatusStyle("#F5B94C", "", "Worth a look") },
            { "Good",    new StatusStyle("#3DD68C", "", "Looks good") },
            { "Info",    new StatusStyle("#6AA8EA", "", "FYI") },
        };
        static readonly Color Accent = (Color)ColorConverter.ConvertFromString("#4F7DF3");
        static readonly HashSet<string> SlowChecks = new HashSet<string>
        {
            "Processor (CPU)", "Drive wear (SMART)", "Windows system image", "Drive file system (chkdsk)", "System files (SFC)"
        };

        public readonly Window Window;
        public string SnapshotPath;
        public bool SnapshotDialog;
        readonly FontFamily iconFont;
        readonly Border rootBorder;
        readonly Button scanButton, deepButton, reportButton, maxButton;
        readonly TextBlock scanGlyph, scanLabel, deepHint, footerText, scoreText, scoreCaption, verdictText, verdictSub;
        readonly TextBlock countProblem, countWarning, countGood, countInfo, progressText, progressCount;
        readonly RadioButton filterAll, filterProblem, filterWarning, filterGood, filterInfo;
        readonly StackPanel progressPanel, resultsPanel, dialogAdmin;
        readonly ProgressBar progress;
        readonly System.Windows.Shapes.Path scoreArc;
        readonly Grid overlay;
        readonly TextBlock dialogTitle, dialogText, toastText, toastGlyph;
        readonly TextBox dialogCommand;
        readonly Border toast;
        readonly Style fixButtonStyle;
        QuickFix pendingFix;
        DispatcherTimer toastTimer;

        readonly List<CheckResult> results = new List<CheckResult>();
        readonly List<Border> cards = new List<Border>();
        readonly Dictionary<string, StackPanel> categoryLists = new Dictionary<string, StackPanel>();
        readonly Dictionary<string, StackPanel> categoryBlocks = new Dictionary<string, StackPanel>();
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        readonly bool startDeep;

        Process proc;
        bool deepRun, stopping, started;
        string reportPath, filter;
        int checksStarted, expected;
        StringBuilder stderr = new StringBuilder();
        double shownScore;
        string scoreSuffix = "";
        DispatcherTimer scoreTimer;

        public MainUi(bool deep)
        {
            startDeep = deep;
            using (var s = Resource("MainWindow.xaml"))
                Window = (Window)XamlReader.Load(s);

            iconFont = (FontFamily)Window.FindResource("Icons");
            rootBorder = Find<Border>("RootBorder");
            scanButton = Find<Button>("ScanButton");
            deepButton = Find<Button>("DeepButton");
            reportButton = Find<Button>("ReportButton");
            maxButton = Find<Button>("MaxButton");
            scanGlyph = Find<TextBlock>("ScanGlyph");
            scanLabel = Find<TextBlock>("ScanLabel");
            deepHint = Find<TextBlock>("DeepHint");
            footerText = Find<TextBlock>("FooterText");
            scoreText = Find<TextBlock>("ScoreText");
            scoreCaption = Find<TextBlock>("ScoreCaption");
            verdictText = Find<TextBlock>("VerdictText");
            verdictSub = Find<TextBlock>("VerdictSub");
            countProblem = Find<TextBlock>("CountProblem");
            countWarning = Find<TextBlock>("CountWarning");
            countGood = Find<TextBlock>("CountGood");
            countInfo = Find<TextBlock>("CountInfo");
            progressText = Find<TextBlock>("ProgressText");
            progressCount = Find<TextBlock>("ProgressCount");
            filterAll = Find<RadioButton>("FilterAll");
            filterProblem = Find<RadioButton>("FilterProblem");
            filterWarning = Find<RadioButton>("FilterWarning");
            filterGood = Find<RadioButton>("FilterGood");
            filterInfo = Find<RadioButton>("FilterInfo");
            progressPanel = Find<StackPanel>("ProgressPanel");
            resultsPanel = Find<StackPanel>("ResultsPanel");
            progress = Find<ProgressBar>("Progress");
            scoreArc = Find<System.Windows.Shapes.Path>("ScoreArc");
            overlay = Find<Grid>("Overlay");
            dialogTitle = Find<TextBlock>("DialogTitle");
            dialogText = Find<TextBlock>("DialogText");
            dialogCommand = Find<TextBox>("DialogCommand");
            dialogAdmin = Find<StackPanel>("DialogAdmin");
            toast = Find<Border>("Toast");
            toastText = Find<TextBlock>("ToastText");
            toastGlyph = Find<TextBlock>("ToastGlyph");
            fixButtonStyle = (Style)Window.FindResource("FixButton");

            Find<Button>("DialogCancel").Click += (s, e) => CloseDialog();
            Find<Button>("DialogRun").Click += (s, e) =>
            {
                var fix = pendingFix;
                CloseDialog();
                if (fix != null) RunFix(fix);
            };
            overlay.MouseLeftButtonDown += (s, e) => { if (e.OriginalSource == overlay) CloseDialog(); };
            Window.PreviewKeyDown += (s, e) =>
            {
                if (e.Key == Key.Escape && overlay.Visibility == Visibility.Visible) { CloseDialog(); e.Handled = true; }
            };

            try
            {
                using (var s = Resource("app.ico"))
                {
                    var icon = BitmapFrame.Create(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                    Window.Icon = icon;
                    Find<Image>("TitleIcon").Source = icon;
                }
            }
            catch { }

            Find<Button>("MinButton").Click += (s, e) => Window.WindowState = WindowState.Minimized;
            maxButton.Click += (s, e) =>
                Window.WindowState = Window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
            Find<Button>("CloseButton").Click += (s, e) => Window.Close();
            Window.StateChanged += (s, e) =>
            {
                bool max = Window.WindowState == WindowState.Maximized;
                rootBorder.Padding = new Thickness(max ? 7 : 0);
                maxButton.Content = max ? "" : "";
            };
            Window.SourceInitialized += (s, e) => ApplyWindowFrame();
            Window.Closing += (s, e) => KillScan();
            EventHandler begin = (s, e) =>
            {
                if (started) return;
                started = true;
                StartScan(startDeep && IsAdmin());
            };
            Window.ContentRendered += begin;
            Window.Loaded += (s, e) => { if (SnapshotPath != null) begin(s, e); };

            scanButton.Click += (s, e) => { if (proc != null) StopScan(); else StartScan(false); };
            deepButton.Click += (s, e) => StartDeepScan();
            reportButton.Click += (s, e) =>
            {
                if (reportPath != null && File.Exists(reportPath))
                    Process.Start(new ProcessStartInfo(reportPath) { UseShellExecute = true });
            };

            filterAll.Checked += (s, e) => SetFilter(null);
            filterProblem.Checked += (s, e) => SetFilter("Problem");
            filterWarning.Checked += (s, e) => SetFilter("Warning");
            filterGood.Checked += (s, e) => SetFilter("Good");
            filterInfo.Checked += (s, e) => SetFilter("Info");

            footerText.Text = Environment.MachineName + (IsAdmin() ? "  ·  running as administrator" : "");
            DrawArc(0);
        }

        // ------------------------------------------------------------------ scanning

        void StartScan(bool deep)
        {
            if (proc != null) return;
            deepRun = deep;
            stopping = false;
            reportPath = null;
            checksStarted = 0;
            expected = deep ? DeepCheckCount : StandardCheckCount;
            stderr = new StringBuilder();
            results.Clear();
            cards.Clear();
            categoryLists.Clear();
            categoryBlocks.Clear();
            resultsPanel.Children.Clear();
            filterAll.IsChecked = true;

            scanLabel.Text = "Stop scan";
            scanGlyph.Text = "";
            deepButton.IsEnabled = false;
            reportButton.IsEnabled = false;
            progressPanel.Visibility = Visibility.Visible;
            progress.Value = 0;
            progressText.Text = "Starting...";
            progressCount.Text = "";
            verdictText.Text = deep ? "Running deep scan..." : "Scanning your PC...";
            verdictSub.Text = deep
                ? "This usually takes 15-30 minutes. You can keep using your PC in the meantime. Nothing will be changed."
                : "Running " + StandardCheckCount + " read-only checks. This takes about 30 seconds.";
            scoreCaption.Text = "scanning";
            UpdateSummary(false);

            string script;
            try
            {
                script = ExtractScript();
            }
            catch (Exception ex)
            {
                ShowFailure("Couldn't prepare the scan: " + ex.Message);
                return;
            }

            string reports = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "PC Health Reports");
            string powershell = System.IO.Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var psi = new ProcessStartInfo(powershell,
                "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -Stream -NoOpen -OutputFolder \"" + reports + "\"" + (deep ? " -Deep" : ""))
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };

            var p = new Process { StartInfo = psi };
            p.OutputDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                string line = e.Data;
                Window.Dispatcher.BeginInvoke(new Action(() => HandleLine(line)));
            };
            p.ErrorDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                lock (stderr) stderr.AppendLine(e.Data);
            };

            try
            {
                p.Start();
            }
            catch (Exception ex)
            {
                ShowFailure("Couldn't start PowerShell: " + ex.Message);
                return;
            }
            proc = p;
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();

            // WaitForExit() also waits for the redirected output to drain, so every result is queued before this.
            var waiter = new Thread(() =>
            {
                p.WaitForExit();
                Window.Dispatcher.BeginInvoke(new Action(() => ScanFinished(p)));
            });
            waiter.IsBackground = true;
            waiter.Start();
        }

        void HandleLine(string line)
        {
            // Markers may follow other console text on the same line, so look for them anywhere.
            int marker = line.IndexOf("##", StringComparison.Ordinal);
            if (marker < 0) return;
            line = line.Substring(marker);
            if (line.StartsWith("##START "))
            {
                checksStarted++;
                string name = line.Substring(8).Trim();
                progressText.Text = "Checking " + name + (SlowChecks.Contains(name) && deepRun ? "  ·  this step can take several minutes" : "...");
                progressCount.Text = Math.Min(checksStarted, expected) + " of " + expected;
            }
            else if (line.StartsWith("##RESULT "))
            {
                Dictionary<string, object> d;
                try { d = json.Deserialize<Dictionary<string, object>>(line.Substring(9)); }
                catch { return; }
                var r = new CheckResult
                {
                    Category = Str(d, "Category"), Name = Str(d, "Name"), Status = Str(d, "Status"),
                    Summary = Str(d, "Summary"), Details = Str(d, "Details"), Advice = Str(d, "Advice"),
                };
                if (!Styles.ContainsKey(r.Status)) r.Status = "Info";
                r.Fixes = ParseFixes(d.ContainsKey("Fixes") ? d["Fixes"] : null);
                results.Add(r);
                AddCard(r);
                progress.Value = Math.Min(1.0, results.Count / (double)expected);
                UpdateSummary(false);
            }
            else if (line.StartsWith("##REPORT "))
            {
                reportPath = line.Substring(9).Trim();
            }
        }

        void ScanFinished(Process p)
        {
            if (p != proc) return;
            proc = null;
            int exitCode = -1;
            try { exitCode = p.ExitCode; } catch { }
            p.Dispose();

            scanLabel.Text = "Scan again";
            scanGlyph.Text = "";
            deepButton.IsEnabled = true;
            progressPanel.Visibility = Visibility.Collapsed;
            reportButton.IsEnabled = reportPath != null && File.Exists(reportPath);

            if (stopping)
            {
                UpdateSummary(false);
                verdictText.Text = "Scan stopped";
                verdictSub.Text = results.Count == 0
                    ? "No checks finished. Click Scan again to start over."
                    : "Showing the " + results.Count + " checks that finished before you stopped the scan.";
                scoreCaption.Text = "partial";
                return;
            }
            if (results.Count == 0)
            {
                string err;
                lock (stderr) err = stderr.ToString().Trim();
                ShowFailure(err.Length > 0 ? FirstLines(err, 4) : "PowerShell exited with code " + exitCode + ".");
                return;
            }

            UpdateSummary(true);
            footerText.Text = Environment.MachineName + "  ·  scanned " + DateTime.Now.ToString("g") + (deepRun ? "  ·  deep scan" : "");
            if (SnapshotPath != null) SaveSnapshot();
        }

        void SaveSnapshot()
        {
            if (SnapshotDialog)
            {
                var fix = results.SelectMany(r => r.Fixes).FirstOrDefault(f => f.Kind == "run");
                if (fix != null) ConfirmFix(fix);
            }
            // Wait for the score animation and layout to settle, then draw the window into a PNG.
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
            timer.Tick += (s, e) =>
            {
                timer.Stop();
                var size = new Size(rootBorder.ActualWidth, rootBorder.ActualHeight);
                var visual = new DrawingVisual();
                using (var dc = visual.RenderOpen())
                {
                    dc.DrawRectangle(Window.Background, null, new Rect(size));
                    dc.DrawRectangle(new VisualBrush(rootBorder), null, new Rect(size));
                }
                var bitmap = new RenderTargetBitmap((int)size.Width, (int)size.Height, 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(visual);
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using (var f = File.Create(SnapshotPath)) encoder.Save(f);
                Window.Close();
            };
            timer.Start();
        }

        void StartDeepScan()
        {
            if (IsAdmin())
            {
                StartScan(true);
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "--deep")
                {
                    UseShellExecute = true,
                    Verb = "runas",
                });
                Window.Close();
            }
            catch (Win32Exception)
            {
                deepHint.Text = "Administrator permission wasn't given, so the deep scan didn't start. Click Run deep scan to try again.";
                deepHint.Foreground = new SolidColorBrush(Styles["Warning"].Color);
            }
        }

        void StopScan()
        {
            if (proc == null) return;
            stopping = true;
            progressText.Text = "Stopping...";
            KillScan();
        }

        // Kills PowerShell and anything it started (sfc, dism, chkdsk, winget).
        void KillScan()
        {
            var p = proc;
            if (p == null) return;
            try
            {
                var kill = Process.Start(new ProcessStartInfo(System.IO.Path.Combine(Environment.SystemDirectory, "taskkill.exe"),
                    "/T /F /PID " + p.Id) { CreateNoWindow = true, UseShellExecute = false });
                if (kill != null) kill.WaitForExit(5000);
            }
            catch
            {
                try { p.Kill(); } catch { }
            }
        }

        void ShowFailure(string message)
        {
            proc = null;
            scanLabel.Text = "Try again";
            scanGlyph.Text = "";
            deepButton.IsEnabled = true;
            progressPanel.Visibility = Visibility.Collapsed;
            verdictText.Text = "The scan couldn't run";
            verdictSub.Text = message;
            scoreCaption.Text = "no result";
        }

        // ------------------------------------------------------------------ summary + score

        void UpdateSummary(bool finished)
        {
            int p = Count("Problem"), w = Count("Warning"), g = Count("Good"), i = Count("Info");
            int total = results.Count;
            countProblem.Text = p.ToString();
            countWarning.Text = w.ToString();
            countGood.Text = g.ToString();
            countInfo.Text = i.ToString();
            filterAll.Content = total > 0 ? "All  ·  " + total : "All";
            filterProblem.Content = "Need attention  ·  " + p;
            filterWarning.Content = "Worth a look  ·  " + w;
            filterGood.Content = "Looking good  ·  " + g;
            filterInfo.Content = "For your info  ·  " + i;

            // While scanning, the ring shows progress; afterwards it shows the health score.
            if (!finished && proc != null)
            {
                scoreArc.Stroke = new SolidColorBrush(Accent);
                scoreSuffix = "%";
                AnimateScore(100.0 * Math.Min(1.0, total / (double)expected), true);
                return;
            }
            double score = total == 0 ? 0 : 100.0 * (g + i + 0.5 * w) / total;
            Color color = p > 0 ? Styles["Problem"].Color : w > 0 ? Styles["Warning"].Color : total > 0 ? Styles["Good"].Color : Accent;
            scoreArc.Stroke = new SolidColorBrush(color);
            scoreSuffix = "";
            AnimateScore(score, total > 0);

            if (!finished) return;
            SortBySeverity();
            scoreCaption.Text = "health score";
            if (p > 0)
            {
                verdictText.Text = "A few things need your attention";
                verdictSub.Text = "We found issues that may affect your PC's speed, safety or reliability. Start with the red items.";
            }
            else if (w > 0)
            {
                verdictText.Text = "Mostly healthy, with a few suggestions";
                verdictSub.Text = "Nothing urgent, but the yellow items are worth a few minutes of your time.";
            }
            else
            {
                verdictText.Text = "Your PC looks healthy!";
                verdictSub.Text = "Everything we checked is in good shape. Nice work keeping it maintained.";
            }
        }

        void AnimateScore(double target, bool hasValue)
        {
            if (scoreTimer != null) scoreTimer.Stop();
            if (!hasValue)
            {
                shownScore = 0;
                scoreText.Text = "--";
                DrawArc(0);
                return;
            }
            double from = shownScore;
            var clock = Stopwatch.StartNew();
            scoreTimer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(15) };
            scoreTimer.Tick += (s, e) =>
            {
                double t = Math.Min(1.0, clock.ElapsedMilliseconds / 650.0);
                double eased = 1 - Math.Pow(1 - t, 3);
                shownScore = from + (target - from) * eased;
                scoreText.Text = Math.Round(shownScore) + scoreSuffix;
                DrawArc(shownScore / 100.0);
                if (t >= 1.0) ((DispatcherTimer)s).Stop();
            };
            scoreTimer.Start();
        }

        void DrawArc(double fraction)
        {
            // Matches the 156px ring in MainWindow.xaml: 6px margin, 10px stroke centred 5px inside the ellipse.
            const double center = 78, radius = 67;
            if (fraction <= 0.001)
            {
                scoreArc.Data = null;
                return;
            }
            fraction = Math.Min(fraction, 0.9999);
            double angle = fraction * 2 * Math.PI;
            var figure = new PathFigure { StartPoint = new Point(center, center - radius), IsClosed = false };
            figure.Segments.Add(new ArcSegment(
                new Point(center + radius * Math.Sin(angle), center - radius * Math.Cos(angle)),
                new Size(radius, radius), 0, fraction > 0.5, SweepDirection.Clockwise, true));
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            scoreArc.Data = geometry;
        }

        // ------------------------------------------------------------------ result cards

        void AddCard(CheckResult r)
        {
            StackPanel list;
            if (!categoryLists.TryGetValue(r.Category, out list))
            {
                var block = new StackPanel { Margin = new Thickness(0, categoryBlocks.Count == 0 ? 4 : 22, 0, 0) };
                block.Children.Add(new TextBlock
                {
                    Text = r.Category.ToUpperInvariant(),
                    FontSize = 11.5,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = Brush("#6F788A"),
                    Margin = new Thickness(2, 0, 0, 10),
                });
                list = new StackPanel();
                block.Children.Add(list);
                resultsPanel.Children.Add(block);
                categoryLists[r.Category] = list;
                categoryBlocks[r.Category] = block;
            }

            var card = BuildCard(r);
            list.Children.Add(card);
            cards.Add(card);
            ApplyFilter();

            card.Opacity = 0;
            var slide = new TranslateTransform(0, 10);
            card.RenderTransform = slide;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            card.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(260)) { EasingFunction = ease });
            slide.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(10, 0, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
        }

        Border BuildCard(CheckResult r)
        {
            StatusStyle st = Styles[r.Status];
            var normal = Brush("#171B24");
            var hover = Brush("#1B202B");
            var card = new Border
            {
                Background = normal,
                BorderBrush = Brush("#232937"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(18, 15, 18, 15),
                Margin = new Thickness(0, 0, 0, 10),
                Tag = r.Status,
            };
            card.MouseEnter += (s, e) => card.Background = hover;
            card.MouseLeave += (s, e) => card.Background = normal;

            var root = new StackPanel();
            card.Child = root;

            var head = new Grid { Background = Brushes.Transparent };
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            root.Children.Add(head);

            var dot = new Grid { Width = 34, Height = 34, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 0, 14, 0) };
            dot.Children.Add(new Ellipse { Fill = Tint(st.Color, 38) });
            dot.Children.Add(new TextBlock
            {
                Text = st.Glyph, FontFamily = iconFont, FontSize = 14, Foreground = new SolidColorBrush(st.Color),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            });
            head.Children.Add(dot);

            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = r.Name, FontSize = 15, FontWeight = FontWeights.SemiBold });
            text.Children.Add(new TextBlock
            {
                Text = r.Summary, FontSize = 13.5, Foreground = Brush("#A3ABB9"),
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0),
            });
            if (r.Fixes.Count > 0)
            {
                var fixes = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
                foreach (var fix in r.Fixes) fixes.Children.Add(BuildFixButton(fix));
                text.Children.Add(fixes);
            }
            Grid.SetColumn(text, 1);
            head.Children.Add(text);

            var tag = new Border
            {
                Background = Tint(st.Color, 30), CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 3, 10, 4),
                VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(14, 5, 0, 0),
                Child = new TextBlock { Text = st.Label, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(st.Color) },
            };
            Grid.SetColumn(tag, 2);
            head.Children.Add(tag);

            bool hasMore = r.Advice.Length > 0 || r.Details.Length > 0;
            var chevron = new TextBlock
            {
                Text = "", FontFamily = iconFont, FontSize = 12, Foreground = Brush("#6F788A"),
                VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(14, 9, 0, 0),
                Visibility = hasMore ? Visibility.Visible : Visibility.Hidden,
            };
            Grid.SetColumn(chevron, 3);
            head.Children.Add(chevron);
            if (!hasMore) return card;

            head.Cursor = Cursors.Hand;
            var body = new StackPanel { Margin = new Thickness(48, 14, 0, 2), Visibility = Visibility.Collapsed };
            root.Children.Add(body);

            if (r.Advice.Length > 0)
            {
                var advice = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 13.5, LineHeight = 20 };
                advice.Inlines.Add(new Run("What to do   ") { FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(st.Color) });
                advice.Inlines.Add(new Run(r.Advice) { Foreground = Brush("#D5DAE3") });
                body.Children.Add(new Border
                {
                    Background = Tint(st.Color, 22), CornerRadius = new CornerRadius(8), Padding = new Thickness(14, 10, 14, 11),
                    Margin = new Thickness(0, 0, 0, r.Details.Length > 0 ? 12 : 0), Child = advice,
                });
            }
            if (r.Details.Length > 0)
            {
                // A read-only TextBox so people can select and copy details (driver names, error codes...).
                var lines = r.Details.Split('\n').Where(l => l.Trim().Length > 0).Select(l => "•  " + l.Trim());
                body.Children.Add(new TextBox
                {
                    Text = string.Join("\n", lines), IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
                    Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0),
                    Foreground = Brush("#8C95A6"), FontSize = 12.5, SelectionBrush = new SolidColorBrush(Accent),
                    CaretBrush = Brushes.Transparent, Cursor = Cursors.IBeam,
                });
            }

            head.MouseLeftButtonUp += (s, e) =>
            {
                bool open = body.Visibility != Visibility.Visible;
                body.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
                chevron.Text = open ? "" : "";
            };
            return card;
        }

        // ------------------------------------------------------------------ quick fixes

        Button BuildFixButton(QuickFix fix)
        {
            bool run = fix.Kind == "run";
            string glyph = !run ? "" : fix.Admin ? "" : "";
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(new TextBlock { Text = glyph, FontFamily = iconFont, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 1, 7, 0) });
            content.Children.Add(new TextBlock { Text = fix.Label, VerticalAlignment = VerticalAlignment.Center });
            var button = new Button
            {
                Style = fixButtonStyle,
                Content = content,
                Margin = new Thickness(0, 0, 8, 6),
                ToolTip = run ? fix.Explain + (fix.Admin ? " Needs administrator permission." : "") : "Opens " + DescribeTarget(fix),
            };
            if (!run)
            {
                button.Background = Brushes.Transparent;
                button.BorderBrush = Brush("#2C3341");
                button.Foreground = Brush("#C9D1DD");
            }
            button.Click += (s, e) =>
            {
                if (run) ConfirmFix(fix); else OpenFix(fix);
            };
            return button;
        }

        static string DescribeTarget(QuickFix fix)
        {
            if (fix.Target.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return "the website in your browser.";
            if (fix.Target.StartsWith("ms-settings:", StringComparison.OrdinalIgnoreCase)) return "the matching page in Windows Settings.";
            if (fix.Target.StartsWith("windowsdefender:", StringComparison.OrdinalIgnoreCase)) return "Windows Security.";
            return fix.Label.StartsWith("Open ") ? fix.Label.Substring(5) + "." : fix.Label + ".";
        }

        void OpenFix(QuickFix fix)
        {
            try
            {
                Process.Start(new ProcessStartInfo(fix.Target, fix.Arguments ?? "") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                ShowToast("Couldn't open " + fix.Label + ": " + ex.Message, true);
            }
        }

        void ConfirmFix(QuickFix fix)
        {
            pendingFix = fix;
            dialogTitle.Text = fix.Label;
            dialogText.Text = fix.Explain;
            dialogCommand.Text = fix.Command.Trim();
            dialogAdmin.Visibility = fix.Admin && !IsAdmin() ? Visibility.Visible : Visibility.Collapsed;
            overlay.Visibility = Visibility.Visible;
            overlay.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(150)));
            Find<Button>("DialogRun").Focus();
        }

        void CloseDialog()
        {
            pendingFix = null;
            overlay.Visibility = Visibility.Collapsed;
        }

        // Runs the fix in its own PowerShell window so the user can watch it; the window stays open afterwards.
        void RunFix(QuickFix fix)
        {
            string label = fix.Label.Replace("'", "''");
            string script =
                "$Host.UI.RawUI.WindowTitle = 'PC Health Check: " + label + "'\n" +
                "Write-Host ''\nWrite-Host '  PC Health Check - " + label + "' -ForegroundColor Cyan\nWrite-Host ''\n" +
                "try {\n" + fix.Command + "\n} catch { Write-Host $_ -ForegroundColor Red }\n" +
                "Write-Host ''\nWrite-Host '  Finished. You can close this window, then click Scan again in PC Health Check.' -ForegroundColor Green\n";
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            string powershell = System.IO.Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var psi = new ProcessStartInfo(powershell, "-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand " + encoded)
            {
                UseShellExecute = true,
            };
            if (fix.Admin && !IsAdmin()) psi.Verb = "runas";
            try
            {
                Process.Start(psi);
                ShowToast("\"" + fix.Label + "\" is running in a new window. When it finishes, click Scan again to see the result.", false);
            }
            catch (Win32Exception)
            {
                ShowToast("Administrator permission wasn't given, so \"" + fix.Label + "\" didn't run.", true);
            }
        }

        void ShowToast(string message, bool warning)
        {
            toastText.Text = message;
            toastGlyph.Text = warning ? "" : "";
            toastGlyph.Foreground = warning ? new SolidColorBrush(Styles["Warning"].Color) : Brush("#8FB0FF");
            toast.Visibility = Visibility.Visible;
            toast.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
            if (toastTimer != null) toastTimer.Stop();
            toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(7) };
            toastTimer.Tick += (s, e) =>
            {
                ((DispatcherTimer)s).Stop();
                var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(300));
                fade.Completed += (s2, e2) => toast.Visibility = Visibility.Collapsed;
                toast.BeginAnimation(UIElement.OpacityProperty, fade);
            };
            toastTimer.Start();
        }

        static List<QuickFix> ParseFixes(object raw)
        {
            var list = new List<QuickFix>();
            if (raw == null) return list;
            IEnumerable<object> items = raw is Dictionary<string, object>
                ? new object[] { raw }
                : raw is System.Collections.IEnumerable && !(raw is string)
                    ? ((System.Collections.IEnumerable)raw).Cast<object>()
                    : new object[0];
            foreach (var item in items)
            {
                var d = item as Dictionary<string, object>;
                if (d == null) continue;
                var fix = new QuickFix
                {
                    Kind = Str(d, "Kind"), Label = Str(d, "Label"), Target = Str(d, "Target"), Arguments = Str(d, "Arguments"),
                    Command = Str(d, "Command"), Explain = Str(d, "Explain"),
                    Admin = Str(d, "Admin").Equals("True", StringComparison.OrdinalIgnoreCase),
                };
                bool valid = fix.Label.Length > 0 && (fix.Kind == "open" ? fix.Target.Length > 0 : fix.Kind == "run" && fix.Command.Length > 0);
                if (valid) list.Add(fix);
            }
            return list;
        }

        static int Severity(string status)
        {
            return status == "Problem" ? 0 : status == "Warning" ? 1 : status == "Info" ? 2 : 3;
        }

        // After a scan: categories with the most serious findings first, and within each, worst cards first.
        void SortBySeverity()
        {
            foreach (var list in categoryLists.Values)
            {
                var ordered = list.Children.Cast<Border>().OrderBy(c => Severity((string)c.Tag)).ToList();
                list.Children.Clear();
                foreach (var c in ordered) list.Children.Add(c);
            }
            var blocks = categoryBlocks
                .Select((pair, index) => new { pair.Key, Block = pair.Value, Index = index })
                .OrderBy(x => categoryLists[x.Key].Children.Cast<Border>().Min(c => Severity((string)c.Tag)))
                .ThenBy(x => x.Index)
                .ToList();
            resultsPanel.Children.Clear();
            for (int i = 0; i < blocks.Count; i++)
            {
                blocks[i].Block.Margin = new Thickness(0, i == 0 ? 4 : 22, 0, 0);
                resultsPanel.Children.Add(blocks[i].Block);
            }
        }

        void SetFilter(string status)
        {
            filter = status;
            ApplyFilter();
        }

        void ApplyFilter()
        {
            foreach (var card in cards)
                card.Visibility = filter == null || (string)card.Tag == filter ? Visibility.Visible : Visibility.Collapsed;
            foreach (var pair in categoryBlocks)
            {
                bool any = categoryLists[pair.Key].Children.Cast<UIElement>().Any(c => c.Visibility == Visibility.Visible);
                pair.Value.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
            }
        }

        // ------------------------------------------------------------------ helpers

        int Count(string status)
        {
            return results.Count(r => r.Status == status);
        }

        T Find<T>(string name) where T : class
        {
            return (T)Window.FindName(name);
        }

        static Stream Resource(string name)
        {
            var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
            if (s == null) throw new InvalidOperationException("Missing embedded resource " + name);
            return s;
        }

        static string ExtractScript()
        {
            string dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PCHealthCheck");
            Directory.CreateDirectory(dir);
            string path = System.IO.Path.Combine(dir, "PCHealthCheck.ps1");
            using (var s = Resource("PCHealthCheck.ps1"))
            using (var f = File.Create(path))
                s.CopyTo(f);
            return path;
        }

        static bool IsAdmin()
        {
            return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
        }

        static string Str(Dictionary<string, object> d, string key)
        {
            object o;
            return d.TryGetValue(key, out o) && o != null ? o.ToString() : "";
        }

        static string FirstLines(string text, int count)
        {
            return string.Join("\n", text.Split('\n').Take(count).Select(l => l.TrimEnd()));
        }

        static SolidColorBrush Brush(string hex)
        {
            return new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        }

        static SolidColorBrush Tint(Color c, byte alpha)
        {
            return new SolidColorBrush(Color.FromArgb(alpha, c.R, c.G, c.B));
        }

        // Windows 11: rounded corners and a subtle border to match the dark theme. Ignored on Windows 10.
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        void ApplyWindowFrame()
        {
            try
            {
                IntPtr hwnd = new WindowInteropHelper(Window).Handle;
                int dark = 1, round = 2, border = 0x003C302A;
                DwmSetWindowAttribute(hwnd, 20, ref dark, 4);    // DWMWA_USE_IMMERSIVE_DARK_MODE
                DwmSetWindowAttribute(hwnd, 33, ref round, 4);   // DWMWA_WINDOW_CORNER_PREFERENCE = round
                DwmSetWindowAttribute(hwnd, 34, ref border, 4);  // DWMWA_BORDER_COLOR
            }
            catch { }
        }
    }
}
