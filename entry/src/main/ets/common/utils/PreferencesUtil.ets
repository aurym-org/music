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
  private static readonly FLUSH_DEBOUNCE_MS: number = 250;
  private flushTimer: number | undefined = undefined;
  private flushPromise: Promise<void> | undefined = undefined;
  private hasPendingChanges: boolean = false;

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
      // Update the in-memory Preferences cache synchronously so existing
      // callers keep their current behavior. Disk persistence is coalesced.
      store.putSync(key, value);
      this.hasPendingChanges = true;
      this.scheduleFlush();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Failed to update preference '${key}': ${message}`);
    }
  }

  private scheduleFlush(delayMs: number = PreferencesUtil.FLUSH_DEBOUNCE_MS): void {
    if (this.flushTimer !== undefined) {
      clearTimeout(this.flushTimer);
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = undefined;
      void this.flushPending();
    }, delayMs);
  }

  /** Persist all pending preference updates without blocking the UI thread. */
  public async flushPending(): Promise<void> {
    if (this.flushTimer !== undefined) {
      clearTimeout(this.flushTimer);
      this.flushTimer = undefined;
    }

    if (this.flushPromise) {
      try {
        await this.flushPromise;
      } catch {
        // The caller that started the flush records the error and schedules
        // the retry. A concurrent lifecycle flush must not create an
        // unhandled rejection while waiting for that same operation.
        return;
      }
      if (this.hasPendingChanges) {
        return this.flushPending();
      }
      return;
    }

    if (!this.hasPendingChanges) {
      return;
    }

    const store = this.preferences;
    if (!store) {
      // Keep the dirty flag so a later lifecycle flush can retry once Context
      // becomes available.
      return;
    }

    this.hasPendingChanges = false;
    try {
      const flushTask = store.flush();
      this.flushPromise = flushTask;
      await flushTask;
    } catch (error) {
      this.hasPendingChanges = true;
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Failed to flush preferences: ${message}`);
      this.scheduleFlush(5000);
    } finally {
      this.flushPromise = undefined;
    }

    // A write may have arrived while flush() was in flight. Schedule another
    // coalesced flush rather than losing that update.
    if (this.hasPendingChanges && this.flushTimer === undefined) {
      this.scheduleFlush();
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
