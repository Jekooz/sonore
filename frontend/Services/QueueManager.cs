using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace YtMusicClient.Services
{
    /// <summary>
    /// The observable playback queue: the track now playing plus everything
    /// coming after it. PlaybackService keeps it in sync; the (future) queue
    /// panel and the transport buttons bind to Current/Upcoming/HasUpcoming.
    /// </summary>
    public sealed class QueueManager : INotifyPropertyChanged
    {
        private QueueTrack _current;

        public event PropertyChangedEventHandler PropertyChanged;

        public QueueTrack Current { get => _current; set => Set(ref _current, value); }

        public ObservableCollection<QueueTrack> Upcoming { get; } = new ObservableCollection<QueueTrack>();

        /// <summary>True when a further track follows the current one.</summary>
        public bool HasUpcoming => Upcoming.Count > 0;

        /// <summary>Rebuild the observable view from the service's queue state.</summary>
        public void Sync(IReadOnlyList<QueueTrack> queue, int index)
        {
            Current = index >= 0 && index < queue.Count ? queue[index] : null;

            Upcoming.Clear();
            for (int i = index + 1; i < queue.Count; i++)
                Upcoming.Add(queue[i]);
            Raise(nameof(HasUpcoming));
        }

        private bool Set<T>(ref T field, T value, [CallerMemberName] string name = null)
        {
            if (Equals(field, value))
                return false;
            field = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
            return true;
        }

        private void Raise(string name) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
