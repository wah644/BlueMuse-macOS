using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.IO;
using BlueMuse.Athena;
using BlueMuse.MuseManagement;
class Program {
    static double[][] Rows(double[,] m) => Enumerable.Range(0,m.GetLength(0)).Select(r=>Enumerable.Range(0,m.GetLength(1)).Select(c=>m[r,c]).ToArray()).ToArray();
    static void Main(string[] args) {
        if (args.Length == 1 && args[0] == "--athena-self-check") {
            Environment.ExitCode = BlueMuse.Athena.Tests.Program.Main();
            return;
        }
        if (args.Length != 1) {
            Console.Error.WriteLine("Usage: BlueMuse.Parity.Tests <fixture-output.json> | --athena-self-check");
            Environment.ExitCode = 2;
            return;
        }
        var random=new Random(843612); var fixtures=new List<object>();
        foreach(var kind in new[]{"eeg","ppg","accelerometer","gyroscope","telemetry"}) {
            for(int n=0;n<100;n++) {
                var b=new byte[kind=="telemetry"?10:20]; random.NextBytes(b);
                var bits=string.Concat(b.Select(x=>Convert.ToString(x,2).PadLeft(8,'0')));
                double[][] rows=kind switch {
                    "eeg"=>new[]{MuseEEGSamples.DecodeEEGSamples(bits)}, "ppg"=>new[]{MusePPGSamples.DecodePPGSamples(bits)},
                    "accelerometer"=>Rows(MuseAccelerometerSamples.DecodeAccelerometerSamples(bits)),
                    "gyroscope"=>Rows(MuseGyroscopeSamples.DecodeGyroscopeSamples(bits)),
                    _=>new[]{MuseTelemetrySamples.DecodeTelemetrySamples(bits)}
                };
                fixtures.Add(new {kind, tag=0, hex=Convert.ToHexString(b), expected=rows});
            }
        }
        foreach(byte tag in new byte[]{0x11,0x12,0x34,0x35,0x36,0x47,0x88,0x98}) {
            var shape=AthenaPacketParser.GetSensorConfig(tag);
            for(int n=0;n<100;n++) {
                var b=new byte[tag==0x88?2:shape.DataLength]; random.NextBytes(b);
                double[][] rows=tag switch {
                    0x11 or 0x12=>Rows(AthenaDecoders.DecodeEEG(b,shape.ChannelCount,shape.SampleCount)).Select(r=>r.Take(4).ToArray()).ToArray(),
                    0x34 or 0x35 or 0x36=>Rows(AthenaDecoders.DecodeOptics(b,tag,shape.ChannelCount,shape.SampleCount)),
                    0x47=>Rows(AthenaDecoders.DecodeAccelerometerGyroscope(b)),
                    _=>new[]{new[]{AthenaDecoders.DecodeBatteryPercent(b)}}
                };
                fixtures.Add(new {kind="athena", tag=(int)tag, hex=Convert.ToHexString(b), expected=rows});
            }
        }
        File.WriteAllText(args[0],JsonSerializer.Serialize(fixtures));
        Console.WriteLine($"Generated {fixtures.Count} fixtures using the unchanged original C# decoders.");
        var timing=new List<object>();
        foreach(bool athena in new[]{false,true}) foreach(bool epoch in new[]{false,true})
        foreach(string sensor in new[]{"EEG","Accelerometer","Gyroscope","PPG","Telemetry"}) {
            double rate=sensor switch { "EEG"=>256, "PPG"=>64, "Telemetry"=>athena?1:0.1, _=>52 };
            int count=sensor switch { "EEG"=>athena?4:12, "PPG"=>athena?1:6, "Telemetry"=>1, _=>3 };
            var blocks=new List<object>(); AthenaTimestampCorrector corrector=null;
            double origin=epoch?1700000000.123456:1000.123456;
            for(int i=0;i<50;i++) {
                double arrival=origin+(i*count/rate)+((i%3)-1)*0.002;
                double stamp=epoch?Math.Floor(arrival*1000)/1000:arrival;
                double[] expected;
                if(athena) {
                    if(sensor=="Telemetry") expected=new[]{stamp};
                    else { if(corrector==null) corrector=new AthenaTimestampCorrector(rate,stamp); expected=corrector.Timestamps(count,stamp); }
                } else {
                    expected=sensor switch {
                        "EEG"=>new MuseEEGSamples { BaseTimestamp=stamp }.Timestamps,
                        "Accelerometer"=>new MuseAccelerometerSamples { BaseTimestamp=stamp }.Timestamps,
                        "Gyroscope"=>new MuseGyroscopeSamples { BaseTimestamp=stamp }.Timestamps,
                        "PPG"=>new MusePPGSamples { BaseTimestamp=stamp }.Timestamps,
                        _=>new MuseTelemetrySamples { BaseTimestamp=stamp }.Timestamps
                    };
                }
                blocks.Add(new {count,arrival,expected});
            }
            timing.Add(new {sensor,athena,clock=epoch?"BLUEMUSE":"LSL_LOCAL_CLOCK_NATIVE",blocks});
        }
        string timingPath=Path.Combine(Path.GetDirectoryName(args[0]),"windows-timing-fixtures.json");
        File.WriteAllText(timingPath,JsonSerializer.Serialize(timing));
        Console.WriteLine("Generated 1,000 timestamp blocks from the unchanged original C# timestamp classes.");
    }
}
