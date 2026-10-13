namespace Screenshooter.Windows.Core.Models
{
    public static class StripCapacity
    {
        public static readonly int[] Options = { 8, 16, 32, 0 }; // 0 = Sin límite

        public static string TitleFor(int capacity)
        {
            return capacity == 0 ? "Sin límite" : $"{capacity} capturas";
        }
    }
}
