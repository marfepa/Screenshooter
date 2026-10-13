namespace Screenshooter.Windows.Core.State
{
    public enum ContinuousCaptureState
    {
        Idle,
        Selecting,
        ScrollPassthrough,
        Processing,
        ScrollCapturing,
        Navigating
    }

    public enum ContinuousCaptureEvent
    {
        HotKey,
        ScrollBegan,
        ScrollEnded,
        SelectionCompleted,
        CaptureFinished,
        ScrollCaptureRequested,
        ScrollCaptureFinished,
        Cancel
    }

    public static class ContinuousCaptureMachine
    {
        public static ContinuousCaptureState Next(ContinuousCaptureState state, ContinuousCaptureEvent evt)
        {
            if (evt == ContinuousCaptureEvent.Cancel)
                return ContinuousCaptureState.Idle;

            return (state, evt) switch
            {
                (ContinuousCaptureState.Idle, ContinuousCaptureEvent.HotKey) => ContinuousCaptureState.Selecting,
                (ContinuousCaptureState.Navigating, ContinuousCaptureEvent.HotKey) => ContinuousCaptureState.Selecting,
                (ContinuousCaptureState.Selecting, ContinuousCaptureEvent.HotKey) => ContinuousCaptureState.Navigating,
                (ContinuousCaptureState.ScrollPassthrough, ContinuousCaptureEvent.HotKey) => ContinuousCaptureState.Navigating,
                (ContinuousCaptureState.Selecting, ContinuousCaptureEvent.ScrollBegan) => ContinuousCaptureState.ScrollPassthrough,
                (ContinuousCaptureState.ScrollPassthrough, ContinuousCaptureEvent.ScrollEnded) => ContinuousCaptureState.Selecting,
                (ContinuousCaptureState.Selecting, ContinuousCaptureEvent.SelectionCompleted) => ContinuousCaptureState.Processing,
                (ContinuousCaptureState.Processing, ContinuousCaptureEvent.CaptureFinished) => ContinuousCaptureState.Selecting,
                (ContinuousCaptureState.Selecting, ContinuousCaptureEvent.ScrollCaptureRequested) => ContinuousCaptureState.ScrollCapturing,
                (ContinuousCaptureState.ScrollCapturing, ContinuousCaptureEvent.ScrollCaptureFinished) => ContinuousCaptureState.Processing,
                _ => state
            };
        }
    }
}
