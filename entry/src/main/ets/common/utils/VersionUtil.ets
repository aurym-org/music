/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */
import { APP_STORAGE_KEYS } from '../constants/AppStorageKeys';

/**
 * 获取当前版本号
 */
export function getCurrentVersion(): number {
  return AppStorage.get<number>(APP_STORAGE_KEYS.SWITCH_VERSION) ?? 0;
}

/**
 * 检查传入的版本是否与当前版本一致
 */
export function isVersionMatch(version: number): boolean {
  return getCurrentVersion() === version;
}

/**
 * 递增版本号，并返回新的版本号
 */
export function incrementVersion(): number {
  const newVersion = getCurrentVersion() + 1;
  AppStorage.setOrCreate(APP_STORAGE_KEYS.SWITCH_VERSION, newVersion);
  return newVersion;
}
