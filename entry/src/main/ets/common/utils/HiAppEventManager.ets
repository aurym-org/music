/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import hiAppEvent from '@ohos.hiviewdfx.hiAppEvent';
import BuildProfile from 'entry/BuildProfile';
import Logger from './Logger';

const TAG = 'HiAppEventManager';

export class HiAppEventManager {
  private static isConfigured: boolean = false;

  public static configure(): void {
    if (HiAppEventManager.isConfigured) {
      return;
    }
    const isDebug: boolean = BuildProfile.DEBUG;

    if (isDebug) {
      hiAppEvent.configure({ disable: false });
      Logger.info(TAG, 'Debug mode: Log enabled.');
    } else {
      hiAppEvent.configure({ disable: true });
      Logger.info(TAG, 'Release mode: Log disabled.');
    }

    HiAppEventManager.isConfigured = true;
  }
}
