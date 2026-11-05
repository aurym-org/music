/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { preferences } from '@kit.ArkData';
import Logger from './Logger';
import { common } from '@kit.AbilityKit';
import { APP_STORAGE_KEYS } from '../constants/AppStorageKeys';

const TAG = 'PreferencesUtil';
const MY_STORE = 'myStore';

export class PreferencesUtil {
  private static preferencesUtil: PreferencesUtil;
  private _preferences: preferences.Preferences | undefined;
  private readonly storeName: string = MY_STORE;

  private get preferences(): preferences.Preferences | undefined {
    if (!this._preferences) {
      const context: common.UIAbilityContext | undefined = AppStorage.get(APP_STORAGE_KEYS.CONTEXT);
      if (!context) {
        return undefined;
      }

      try {
        const options: preferences.Options = { name: this.storeName };
        this._preferences = preferences.getPreferencesSync(context, options);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.error(TAG, `Failed to open preferences: ${message}`);
        return undefined;
      }
    }
    return this._preferences;
  }

  public static getInstance(): PreferencesUtil {
    if (!PreferencesUtil.preferencesUtil) {
      PreferencesUtil.preferencesUtil = new PreferencesUtil();
    }
    return PreferencesUtil.preferencesUtil;
  }

  // Persist a value.
  preferencesPut(key: string, value: preferences.ValueType): void {
    const store = this.preferences;
    if (!store) {
      Logger.warn(TAG, 'Preferences store is unavailable; write skipped');
      return;
    }
    try {
      store.putSync(key, value);
      store.flushSync();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Failed to persist preference '${key}': ${message}`);
    }
  }

  // Check whether a key exists.
  preferencesHas(key: string): boolean {
    const store = this.preferences;
    if (!store) {
      return false;
    }
    try {
      return store.hasSync(key);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Failed to read preference existence for '${key}': ${message}`);
      return false;
    }
  }

  getValue(key: string): preferences.ValueType | undefined {
    const store = this.preferences;
    if (!store) {
      return undefined;
    }
    try {
      return store.getSync(key, undefined);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Failed to read preference '${key}': ${message}`);
      return undefined;
    }
  }
}
