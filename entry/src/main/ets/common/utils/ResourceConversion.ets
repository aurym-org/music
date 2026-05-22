/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { common } from '@kit.AbilityKit';

export class ResourceConversion {
  private context: common.UIAbilityContext | undefined = undefined;

  constructor() {
    this.context = AppStorage.get('context');
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