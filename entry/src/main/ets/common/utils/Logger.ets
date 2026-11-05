/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Centralized application logger.
 * All call-site arguments are joined into one public log message so callers
 * can consistently pass a tag and a message without depending on a fixed
 * number of format placeholders.
 */
class Logger {
  private readonly domain: number = 0xFF00;
  private readonly prefix: string = '[AurymMusic]';

  debug(...args: string[]): void {
    hilog.debug(this.domain, this.prefix, '%{public}s', args.join(' '));
  }

  info(...args: string[]): void {
    hilog.info(this.domain, this.prefix, '%{public}s', args.join(' '));
  }

  warn(...args: string[]): void {
    hilog.warn(this.domain, this.prefix, '%{public}s', args.join(' '));
  }

  error(...args: string[]): void {
    hilog.error(this.domain, this.prefix, '%{public}s', args.join(' '));
  }
}

export default new Logger();
