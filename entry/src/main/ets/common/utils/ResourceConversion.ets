/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { common } from '@kit.AbilityKit';
import { APP_STORAGE_KEYS } from '../constants/AppStorageKeys';

export class ResourceConversion {
  private context: common.UIAbilityContext | undefined = undefined;

  constructor() {
    this.context = AppStorage.get(APP_STORAGE_KEYS.CONTEXT);
  }

  getStringValueFromResource(res: Resource) {
    if (!this.context) {
      return;
    }
    if (!res || !res.id) {
      return;
    }
    return this.context.resourceManager.getStringSync(res.id);
  }
}