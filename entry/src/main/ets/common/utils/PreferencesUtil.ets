/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { preferences } from '@kit.ArkData';
import Logger from './Logger';
import { common } from '@kit.AbilityKit';

const TAG = 'PreferencesUtil';
const MY_STORE = 'myStore';

export class PreferencesUtil {
  private static preferencesUtil: PreferencesUtil;
  private _preferences: preferences.Preferences | undefined;
  private storeName: string = MY_STORE;

  private get preferences(): preferences.Preferences {
    if (!this._preferences) {
      const context: common.UIAbilityContext | undefined = AppStorage.get('context');
      if (context) {
        let options: preferences.Options = { name: this.storeName };
        this._preferences = preferences.getPreferencesSync(context, options);
      }
    }
    return this._preferences!;
  }

  public static getInstance(): PreferencesUtil {
    if (!PreferencesUtil.preferencesUtil) {
      PreferencesUtil.preferencesUtil = new PreferencesUtil();
    }
    return PreferencesUtil.preferencesUtil;
  }

  // Clear the data of the preferences
  preferencesFlush(preferences: preferences.Preferences) {
    preferences.flush((err) => {
      if (err) {
        Logger.error(TAG, `Failed to flush. Code:${err.code}, message:${err.message}`);
      }
    })
  }

  // Delete the data of the preferences
  preferencesPut(key: string, value: preferences.ValueType) {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return;
    }
    this.preferences.putSync(key, value);
    this.preferences.flushSync();
  }

  // Determine whether there is a certain data in the preferences
  preferencesHas(key: string): boolean {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return false;
    }
    return this.preferences.hasSync(key);
  }

  removePreferencesFromCache(): void {
    preferences.removePreferencesFromCache(AppStorage.get('context'), MY_STORE);
  }

  getValue(key: string): preferences.ValueType | undefined {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return undefined;
    }
    return this.preferences.getSync(key, undefined);
  }

  getAll(): preferences.ValueType | undefined {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return undefined;
    }
    return this.preferences.getAllSync();
  }

  // Remove data by key
  async removeKey(key: string) {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return;
    }
    this.preferences.deleteSync(key);
  }
}