/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

// [Start media_tools]
export class MediaTools {
  /**
   * @param {string} value - Data value
   * @return {string} - If the date is less than two digits, add 0
   */
  private static fill(value: number): string {
    return value.toString().padStart(2, '0');
  }

  static msToCountdownTime(ms: number): string {
    const safeMs = Number.isFinite(ms) ? Math.max(0, Math.floor(ms)) : 0;
    if (safeMs === 0) {
      return '00:00';
    }

    const millisecondsPerMinute = 1000 * 60;
    const millisecondsPerHour = millisecondsPerMinute * 60;
    const millisecondsPerDay = millisecondsPerHour * 24;
    const days = Math.floor(safeMs / millisecondsPerDay);
    const hours = Math.floor((safeMs % millisecondsPerDay) / millisecondsPerHour);
    const minutes = Math.floor((safeMs % millisecondsPerHour) / millisecondsPerMinute);
    const seconds = Math.floor((safeMs % millisecondsPerMinute) / 1000);
    const dayPrefix = days > 0 ? `${MediaTools.fill(days)}:` : '';
    const hourPrefix = hours > 0 || days > 0 ? `${MediaTools.fill(hours)}:` : '';
    return `${dayPrefix}${hourPrefix}${MediaTools.fill(minutes)}:${MediaTools.fill(seconds)}`;
  }
}
// [End media_tools]
