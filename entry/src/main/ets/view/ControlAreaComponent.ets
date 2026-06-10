/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { PromptAction } from '@kit.ArkUI';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { MusicPlayMode, PlayerConstants, PlayModeSwitchList, VOLUME_ID, PLAY_MODE_ID } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { BreakpointType } from '../common/utils/BreakpointSystem';
import Logger from '../common/utils/Logger';
import { ResourceConversion } from '../common/utils/ResourceConversion';
import { SongItem } from '../viewmodel/SongData';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';
import { PreferencesUtil } from '../common/utils/PreferencesUtil';
import { PlaylistControl } from './PlaylistControl';
import { SpeedControl } from './SpeedControl';
import { VolumeControl } from './VolumeControl';
import { MediaTools } from '../common/utils/mediautils/MediaTools';

const TAG = 'ControlAreaComponent';

@Component
export struct ControlAreaComponent {
  @StorageProp('currentBreakpoint') currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink('isPlay') isPlay: boolean = false;
  @StorageProp('currentTime') currentTime: string = '00:00';
  @StorageProp('totalTime') totalTime: string = '00:00';
  @StorageLink('progress') value: number = 0;
  @StorageProp('progressMax') max: number = 0;
  @StorageLink('pageShowTime') pageShowTime: number = 0;
  @StorageProp('songList') songList: SongItem[] = [];
  @StorageLink('playMode') playMode: MusicPlayMode = PreferencesUtil.getInstance().getValue(PLAY_MODE_ID) as MusicPlayMode ?? MusicPlayMode.ORDER;
  @StorageProp('selectIndex') selectIndex: number = 0;
  @StorageLink('isSilentMode') @Watch('isSilentModeChange') isSilentMode: boolean = false;
  @StorageLink('isLoading') isLoading: boolean = true;
  @StorageLink('currentVolume') @Watch('currentVolumeChange') volume: number = 0;
  private resourceConversion: ResourceConversion = new ResourceConversion();
  uiContext: UIContext = this.getUIContext();
  promptAction: PromptAction = this.uiContext.getPromptAction();

  isSilentModeChange() {
    Logger.info(TAG, `isSilentMode is change,current isSilentMode is ${this.isSilentMode}`);
    MediaControlCenter.getInstance().setSilentMode(this.isSilentMode);
  }

  currentVolumeChange() {
    Logger.info(TAG, `volume is change, current volume is ${this.volume}`);
    MediaControlCenter.getInstance().setVolume(this.volume);
  }

  switchPlayMode() {
    const curIndex = PlayModeSwitchList.indexOf(this.playMode);
    const nextIndex = (curIndex === -1 ? 0 : curIndex + 1) % PlayModeSwitchList.length;
    this.playMode = PlayModeSwitchList[nextIndex];
    Logger.info(TAG, 'playMode is ' + MusicPlayMode[this.playMode]);
    let msgRes: Resource;
    switch (this.playMode) {
      case MusicPlayMode.ORDER:
        msgRes = $r('app.string.sequential_playback');
        break;
      case MusicPlayMode.RANDOM:
        msgRes = $r('app.string.random_playback');
        break;
      case MusicPlayMode.SINGLE_CYCLE:
      default:
        msgRes = $r('app.string.single_playback');
        break;
    }
    this.promptAction.openToast({
      message: this.resourceConversion.getStringValueFromResource(msgRes)
    });
    MediaControlCenter.getInstance().setPlayMode(this.playMode);
  }

  build() {
    Column() {
      Row() {
        SymbolGlyph(this.playMode === MusicPlayMode.ORDER ? $r('sys.symbol.order_play') :
          this.playMode === MusicPlayMode.RANDOM ? $r('sys.symbol.shuffle') : $r('sys.symbol.repeat_1'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => {
            this.switchPlayMode()
          })

        PlaylistControl()

        SymbolGlyph(this.isSilentMode ? $r('sys.symbol.bell_slash') : $r('sys.symbol.bell'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => {
            this.isSilentMode = !this.isSilentMode;
            if (this.isSilentMode) {
              this.volume = 0;
            } else {
              let preVolume: number = PreferencesUtil.getInstance().getValue(VOLUME_ID) as number;
              this.volume = preVolume ? preVolume : 10;
            }
          })

        SpeedControl()
        VolumeControl()
      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceBetween)

      Column() {
        Slider({
          min: 0,
          max: this.max,
          step: 1,
          style: SliderStyle.OutSet,
          value: this.value
        })
          .selectedColor($r('app.color.slider_select'))
          .trackColor($r('app.color.slider_track'))
          .onChange((value: number, mode: SliderChangeMode) => {
            AppStorage.setOrCreate('currentTime', MediaTools.msToCountdownTime(value));
            if (mode === SliderChangeMode.End) {
              MediaControlCenter.getInstance().seek(value);
            }
            this.pageShowTime = 0;
          })
          .height($r('app.float.slider_height'))
          .margin({
            left: new BreakpointType({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint),
            right: new BreakpointType({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint)
          })
          .hitTestBehavior(HitTestMode.Block)
        Row() {
          Text(this.currentTime)
            .fontColor($r('app.color.play_text_color'))
            .fontSize($r('app.float.singer_title_sm'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .lineHeight('14vp')
          Text(this.totalTime)
            .fontColor($r('app.color.play_text_color'))
            .fontSize($r('app.float.singer_title_sm'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .lineHeight('14vp')
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .margin({
        top: $r('app.float.slider_margin_top'),
        bottom: this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG ?
          $r('app.float.slider_margin_bottom_lg') : $r('app.float.slider_margin_bottom')
      })

      Row() {
        Image($r('app.media.ic_public_forward'))
          .controlImageBuilder()
          .width(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG ?
            $r('app.float.control_width_lg') : $r('app.float.control_width'))
          .onClick(() => {
            MediaControlCenter.getInstance().playPrevious();
            this.pageShowTime = 0;
          })
        if (this.isLoading) {
          LoadingProgress()
            .width(new BreakpointType({
              sm: $r('app.float.image_play_width'),
              md: $r('app.float.image_play_width'),
              lg: $r('app.float.image_play_width_lg')
            }).getValue(this.currentBreakpoint))
            .height(new BreakpointType({
              sm: $r('app.float.image_play_width'),
              md: $r('app.float.image_play_width'),
              lg: $r('app.float.image_play_width_lg')
            }).getValue(this.currentBreakpoint))
            .color(Color.White)
            .opacity(0.86)
        } else {
          Image(this.isPlay ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
            .controlImageBuilder()
            .width(new BreakpointType({
              sm: $r('app.float.image_play_width'),
              md: $r('app.float.image_play_width'),
              lg: $r('app.float.image_play_width_lg')
            }).getValue(this.currentBreakpoint))
            .onClick(() => {
              if (this.isPlay) {
                MediaControlCenter.getInstance().pause()
              } else {
                MediaControlCenter.getInstance().play()
              }
              this.pageShowTime = 0;
            })
        }
        Image($r('app.media.ic_public_next'))
          .controlImageBuilder()
          .width(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG ?
            $r('app.float.control_width_lg') : $r('app.float.control_width'))
          .onClick(() => {
            MediaControlCenter.getInstance().playNext();
            this.pageShowTime = 0;
          })
      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({
        left: $r('app.float.control_padding'),
        right: $r('app.float.control_padding')
      })
    }
  }
}

@Extend(Image)
function controlImageBuilder() {
  .aspectRatio(1)
  .opacity(0.86)
  .objectFit(ImageFit.Contain)
}