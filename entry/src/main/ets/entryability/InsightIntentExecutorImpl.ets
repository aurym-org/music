/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { insightIntent, InsightIntentExecutor } from '@kit.AbilityKit';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';

export default class InsightIntentExecutorImpl extends InsightIntentExecutor {
  async onExecuteInUIAbilityBackgroundMode(intentName: string):
    Promise<insightIntent.ExecuteResult> {
    switch (intentName) {
      case 'PlayMusicList':
      case 'PlayAudio':
        return this.playFunc();
      default:
        break;
    }
    return Promise.resolve({
      code: -1,
      result: {
        message: 'unknown intent'
      }
    } as insightIntent.ExecuteResult)
  }

  private async playMusic() {
    await MediaControlCenter.getInstance().init();
    MediaControlCenter.getInstance().switchToIndex(0);
  }

  /**
   * Realize the invocation of the playback function
   *
   */
  private async playFunc(): Promise<insightIntent.ExecuteResult> {
    this.playMusic();
    return Promise.resolve({
      code: 0,
      result: {
        message: 'Intent execute succeed'
      }
    } as insightIntent.ExecuteResult)
  }
}