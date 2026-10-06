using System;
using System.Linq;
using NAudio.Dsp;
using NAudio.Wave;

namespace YtMusicClient.Services
{
    /// <summary>
    /// 10-band peaking-EQ chain (BiQuad biquads, standard octave centers) as an
    /// ISampleProvider, so the engine's graph is
    /// RangeCachedStream → MediaFoundationReader → Equalizer10 → Volume → WasapiOut
    /// and the equalizer has real DSP access to the decoded samples.
    /// NAudio 2.2.1 ships BiQuadFilter but no Equalizer class, so this is the
    /// minimal chain: all gains default to 0 dB (transparent).
    /// </summary>
    public sealed class Equalizer10 : ISampleProvider
    {
        /// <summary>Standard 10-band center frequencies in Hz.</summary>
        public static readonly int[] CenterFreqsHz = { 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };

        private readonly ISampleProvider _source;
        private readonly BiQuadFilter[] _filters;
        private readonly int _sampleRate;

        public Equalizer10(ISampleProvider source)
        {
            _source = source ?? throw new ArgumentNullException(nameof(source));
            _sampleRate = source.WaveFormat.SampleRate;
            _filters = CenterFreqsHz
                .Select(f => BiQuadFilter.PeakingEQ(_sampleRate, f, 1.0f, 0f))
                .ToArray();
        }

        public WaveFormat WaveFormat => _source.WaveFormat;

        /// <summary>Set one band's gain in dB (-12..+12 sensible); applies immediately.</summary>
        public void SetBand(int index, float gainDb)
        {
            if (index < 0 || index >= _filters.Length)
                throw new ArgumentOutOfRangeException(nameof(index));
            _filters[index].SetPeakingEq(_sampleRate, CenterFreqsHz[index], 1.0f, Math.Clamp(gainDb, -12f, 12f));
        }

        public int Read(float[] buffer, int offset, int count)
        {
            int read = _source.Read(buffer, offset, count);
            for (int i = 0; i < read; i++)
            {
                float sample = buffer[offset + i];
                for (int b = 0; b < _filters.Length; b++)
                    sample = _filters[b].Transform(sample);
                buffer[offset + i] = sample;
            }
            return read;
        }
    }
}
