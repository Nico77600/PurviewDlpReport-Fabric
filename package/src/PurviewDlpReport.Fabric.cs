// Purview DLP Report for Microsoft Fabric - CSV normaliser.
// Reads the CSV files written by Invoke-PurviewDlpReport.ps1 (any delimiter, with or without the
// Recipients column) and writes one clean comma-separated file for the lakehouse table dlp_messages.
// One row per Message ID is kept (first occurrence), like the report itself.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace PurviewDlpReportFabric
{
    public sealed class NormalizeResult
    {
        public long Rows;
        public long Duplicates;
        public long UnresolvedRows;
        public string TimeZoneLabel = "";
        public string FirstDetection = "";
        public string LastDetection = "";
        public HashSet<string> SenderIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> UnresolvedSenders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    }

    public static class Normalizer
    {
        public static readonly string[] OutputColumns = { "MessageId", "DetectedAt", "DetectedDate", "SenderAddress", "SenderId", "Subject", "RecipientCount" };

        public static NormalizeResult Run(string[] inputFiles, string delimiter, IDictionary<string, string> addressToUserId, string outputFile)
        {
            var result = new NormalizeResult();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            char d = string.IsNullOrEmpty(delimiter) ? ';' : delimiter[0];
            using (var w = new StreamWriter(new FileStream(outputFile, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16), new UTF8Encoding(false)))
            {
                w.NewLine = "\n";
                w.WriteLine(string.Join(",", OutputColumns));
                foreach (var file in inputFiles)
                {
                    using (var r = new StreamReader(file, Encoding.UTF8, true, 1 << 16))
                    {
                        var header = ReadRecord(r, d);
                        if (header == null) continue;
                        int iTime = -1, iSender = -1, iSubject = -1, iCount = -1, iId = -1;
                        for (int i = 0; i < header.Count; i++)
                        {
                            string h = header[i].Trim();
                            if (h.StartsWith("Detection time", StringComparison.OrdinalIgnoreCase))
                            {
                                iTime = i;
                                int a = h.IndexOf('('), b = h.LastIndexOf(')');
                                if (a > 0 && b > a) result.TimeZoneLabel = h.Substring(a + 1, b - a - 1);
                            }
                            else if (h.Equals("Sender", StringComparison.OrdinalIgnoreCase)) iSender = i;
                            else if (h.Equals("Subject", StringComparison.OrdinalIgnoreCase)) iSubject = i;
                            else if (h.Equals("Recipient count", StringComparison.OrdinalIgnoreCase)) iCount = i;
                            else if (h.Equals("Message ID", StringComparison.OrdinalIgnoreCase)) iId = i;
                        }
                        if (iTime < 0 || iSender < 0 || iId < 0)
                            throw new InvalidDataException("Unexpected CSV header in " + file + ": " + string.Join("|", header));

                        List<string> f;
                        while ((f = ReadRecord(r, d)) != null)
                        {
                            if (f.Count <= iId) continue;
                            string id = f[iId].Trim();
                            if (id.Length == 0) continue;
                            if (!seen.Add(id)) { result.Duplicates++; continue; }

                            string time = f[iTime].Trim();
                            DateTime t;
                            if (!DateTime.TryParseExact(time, "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out t))
                                throw new InvalidDataException("Unexpected detection time '" + time + "' in " + file);
                            string at = t.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
                            if (result.FirstDetection.Length == 0 || string.CompareOrdinal(at, result.FirstDetection) < 0) result.FirstDetection = at;
                            if (string.CompareOrdinal(at, result.LastDetection) > 0) result.LastDetection = at;

                            string sender = Unprotect(f[iSender]).Trim().ToLowerInvariant();
                            string senderId;
                            if (sender.Length > 0 && addressToUserId.TryGetValue(sender, out senderId)) result.SenderIds.Add(senderId);
                            else { senderId = ""; result.UnresolvedRows++; if (sender.Length > 0) result.UnresolvedSenders.Add(sender); }

                            string subject = iSubject >= 0 && f.Count > iSubject ? Unprotect(f[iSubject]) : "";
                            string count = iCount >= 0 && f.Count > iCount ? f[iCount].Trim() : "";
                            int n;
                            if (count.Length > 0 && !int.TryParse(count, NumberStyles.None, CultureInfo.InvariantCulture, out n)) count = "";

                            w.Write(Csv(id)); w.Write(',');
                            w.Write(at); w.Write(',');
                            w.Write(at.Substring(0, 10)); w.Write(',');
                            w.Write(Csv(sender)); w.Write(',');
                            w.Write(senderId); w.Write(',');
                            w.Write(Csv(subject)); w.Write(',');
                            w.Write(count); w.Write('\n');
                            result.Rows++;
                        }
                    }
                }
            }
            return result;
        }

        // The report protects values that a spreadsheet would read as a formula with a leading quote.
        static string Unprotect(string v)
        {
            if (v.Length > 1 && v[0] == '\'' && (v[1] == '=' || v[1] == '+' || v[1] == '-' || v[1] == '@' || v[1] == '\t' || v[1] == '\r')) return v.Substring(1);
            return v;
        }

        public static string Csv(string v)
        {
            if (string.IsNullOrEmpty(v)) return "";
            v = v.Replace("\r\n", " ").Replace('\r', ' ').Replace('\n', ' ');
            bool quote = v.IndexOf(',') >= 0 || v.IndexOf('"') >= 0 || v[0] == ' ' || v[v.Length - 1] == ' ';
            return quote ? "\"" + v.Replace("\"", "\"\"") + "\"" : v;
        }

        // RFC 4180 record reader (quoted fields may contain the delimiter, quotes and line breaks).
        public static List<string> ReadRecord(TextReader r, char d)
        {
            if (r.Peek() < 0) return null;
            var fields = new List<string>();
            var sb = new StringBuilder();
            bool quoted = false;
            while (true)
            {
                int c = r.Read();
                if (c < 0) { fields.Add(sb.ToString()); return fields; }
                char ch = (char)c;
                if (quoted)
                {
                    if (ch == '"') { if (r.Peek() == '"') { r.Read(); sb.Append('"'); } else quoted = false; }
                    else sb.Append(ch);
                }
                else if (ch == '"') quoted = true;
                else if (ch == d) { fields.Add(sb.ToString()); sb.Clear(); }
                else if (ch == '\r') { if (r.Peek() == '\n') r.Read(); fields.Add(sb.ToString()); return fields; }
                else if (ch == '\n') { fields.Add(sb.ToString()); return fields; }
                else sb.Append(ch);
            }
        }
    }

    // Reads a comma-separated file written by this tool by batches of typed rows (DataTable), for SqlBulkCopy.
    // Column types: string, int, bigint, datetime, date, bool. Text values longer than maxChars[i] characters are cut.
    public sealed class CsvBatchReader : IDisposable
    {
        readonly StreamReader _r;
        readonly string[] _types;
        readonly int[] _index;
        readonly int[] _maxChars;
        public readonly System.Data.DataTable Table = new System.Data.DataTable();
        public long Rows;

        public CsvBatchReader(string csvPath, string[] names, string[] types, int[] maxChars)
        {
            _types = types; _maxChars = maxChars;
            for (int i = 0; i < names.Length; i++)
            {
                Type t;
                switch (types[i])
                {
                    case "int": t = typeof(int); break;
                    case "bigint": t = typeof(long); break;
                    case "datetime": case "date": t = typeof(DateTime); break;
                    case "bool": t = typeof(bool); break;
                    default: t = typeof(string); break;
                }
                Table.Columns.Add(names[i], t);
            }
            _r = new StreamReader(csvPath, Encoding.UTF8, true, 1 << 16);
            var header = Normalizer.ReadRecord(_r, ',') ?? new List<string>();
            _index = new int[names.Length];
            for (int i = 0; i < names.Length; i++)
            {
                _index[i] = header.FindIndex(h => string.Equals(h, names[i], StringComparison.OrdinalIgnoreCase));
                if (_index[i] < 0) throw new InvalidDataException("Column " + names[i] + " missing in " + csvPath);
            }
        }

        // Fills Table with up to batchRows rows; returns false when the file is finished and Table is empty.
        public bool ReadBatch(int batchRows)
        {
            Table.Clear();
            List<string> f;
            var values = new object[_index.Length];
            while (Table.Rows.Count < batchRows && (f = Normalizer.ReadRecord(_r, ',')) != null)
            {
                if (f.Count == 1 && f[0].Length == 0) continue;
                for (int i = 0; i < _index.Length; i++)
                {
                    string v = _index[i] < f.Count ? f[_index[i]] : "";
                    if (v.Length == 0) { values[i] = DBNull.Value; continue; }
                    switch (_types[i])
                    {
                        case "int": values[i] = int.Parse(v, CultureInfo.InvariantCulture); break;
                        case "bigint": values[i] = long.Parse(v, CultureInfo.InvariantCulture); break;
                        case "datetime": values[i] = DateTime.ParseExact(v, "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture); break;
                        case "date": values[i] = DateTime.ParseExact(v.Substring(0, 10), "yyyy-MM-dd", CultureInfo.InvariantCulture); break;
                        case "bool": values[i] = v == "1" || v.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                        default: values[i] = _maxChars[i] > 0 && v.Length > _maxChars[i] ? v.Substring(0, _maxChars[i]) : v; break;
                    }
                }
                Table.Rows.Add(values);
            }
            Rows += Table.Rows.Count;
            return Table.Rows.Count > 0;
        }

        public void Dispose() { _r.Dispose(); Table.Dispose(); }
    }
}