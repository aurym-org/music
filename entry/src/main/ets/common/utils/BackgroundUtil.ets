/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

// [Start background_util]
import { wantAgent, common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import Logger from './Logger';

const TAG = 'BackgroundUtil';

export class BackgroundUtil {
  private static operationPromise: Promise<void> = Promise.resolve();
  private static operationGeneration: number = 0;
  private static isRunning: boolean = false;

  /**
   * Enqueue background-task operations so a late start cannot run after a stop.
   */
  public static startContinuousTask(context?: common.UIAbilityContext): void {
    if (!context) {
      Logger.warn(TAG, 'Cannot start continuous task: context is unavailable');
      return;
    }

    const generation = ++BackgroundUtil.operationGeneration;
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };

    const operation = BackgroundUtil.operationPromise.then(async () => {
      if (generation !== BackgroundUtil.operationGeneration) {
        return;
      }
      if (BackgroundUtil.isRunning) {
        return;
      }
      const wantAgentObj: Object = await wantAgent.getWantAgent(wantAgentInfo);
      if (generation !== BackgroundUtil.operationGeneration) {
        return;
      }
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        wantAgentObj
      );
      BackgroundUtil.isRunning = true;
      Logger.info(TAG, 'startBackgroundRunning succeeded');
    });

    BackgroundUtil.operationPromise = operation.then(
      () => undefined,
      (error: BusinessError) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.error(TAG, `startBackgroundRunning failed: ${message}`);
      }
    );
  }

  /**
   * Stop the background task after any earlier start request has settled.
   */
  public static stopContinuousTask(context: common.UIAbilityContext): void {
    BackgroundUtil.operationGeneration++;
    const operation = BackgroundUtil.operationPromise.then(async () => {
      if (!BackgroundUtil.isRunning) {
        return;
      }
      await backgroundTaskManager.stopBackgroundRunning(context);
      BackgroundUtil.isRunning = false;
      Logger.info(TAG, 'stopBackgroundRunning succeeded');
    });

    BackgroundUtil.operationPromise = operation.then(
      () => undefined,
      (error: BusinessError) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.error(TAG, `stopBackgroundRunning failed: ${message}`);
      }
    );
  }
}

// [End background_util]
