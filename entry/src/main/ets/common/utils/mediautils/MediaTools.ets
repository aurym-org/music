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
    if (!ms) {
      return '00:00';
    }
    const days = Math.floor(ms / (1000 * 60 * 60 * 24));
    const hours = Math.floor((ms % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    const minutes = Math.floor((ms % (1000 * 60 * 60)) / (1000 * 60));
    const seconds = Math.floor((ms % (1000 * 60)) / 1000);
    return `${(days ? MediaTools.fill(days) + ':' : '')}${(hours ? MediaTools.fill(hours) + ':' : '')}${MediaTools.fill(minutes)}:${MediaTools.fill(seconds)} `.trim();
  }
}
// [End media_tools]