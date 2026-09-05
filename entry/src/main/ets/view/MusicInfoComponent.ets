/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { APP_STORAGE_KEYS } from '../common/constants/AppStorageKeys';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { AVSessionController } from '../common/utils/mediautils/AVSessionController';
import { SongItem } from '../viewmodel/SongData';
import { ControlAreaComponent } from './ControlAreaComponent';

@Preview
@Component
export struct MusicInfoComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp(APP_STORAGE_KEYS.IS_FOLD_FULL) isFoldFull: boolean = false;
  @StorageProp(APP_STORAGE_KEYS.SONG_LIST) songList: SongItem[] = [];
  @StorageProp(APP_STORAGE_KEYS.SELECT_INDEX) selectIndex: number = 0;
  @StorageLink(APP_STORAGE_KEYS.IS_FAVORITE) isFavorite: boolean = false;
  @StorageLink(APP_STORAGE_KEYS.CURRENT_PIXEL_MAP) currentPixelMap: PixelMap | undefined = undefined;

  build() {
    GridRow({
      columns: {
        xs: BreakpointConstants.COLUMN_SM,
        sm: BreakpointConstants.COLUMN_SM,
        md: BreakpointConstants.COLUMN_MD
      },
      gutter: BreakpointConstants.GUTTER_MUSIC_X,
      breakpoints: { reference: BreakpointsReference.ComponentSize }
    }) {
      GridCol({
        span: {
          xs: BreakpointConstants.SPAN_SM,
          sm: BreakpointConstants.SPAN_SM,
          md: BreakpointConstants.SPAN_MD
        },
        offset: { md: BreakpointConstants.OFFSET_MD }
      }) {
        Column() {
          Column() {
            this.CoverInfo()
            this.MusicInfo()
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
          ControlAreaComponent()
        }
        .height(StyleConstants.FULL_HEIGHT)
        .width(StyleConstants.FULL_HEIGHT)
        .clip(false)
      }
    }
  }

  @Builder
  CoverInfo() {
    Row() {
      Image(this.currentPixelMap)
        .width(this.isFoldFull ? '70%': StyleConstants.FULL_WIDTH)
        .aspectRatio(1)
        .objectFit(ImageFit.Contain)
        .backgroundColor(Color.Black)
        .borderRadius($r('app.float.cover_radius_label'))
        .shadow({
          radius: $r('app.float.shadow_radius'),
          color: $r('app.color.shadow_color'),
          offsetX: 0,
          offsetY: 8
        })
        .margin("3vp")
    }
  }

  @Builder
  MusicInfo() {
    Row() {
      Column() {
        Text(this.songList[this.selectIndex]?.title)
          .fontSize(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD && !this.isFoldFull ?
            $r('app.float.title_font_play_md') : $r('app.float.title_font_play'))
          .fontColor(Color.White)
          .opacity(0.86)
          .fontWeight(FontWeight.Bold)
          .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
        Text(this.songList[this.selectIndex]?.singer)
          .textAlign(TextAlign.Start)
          .fontSize(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD && !this.isFoldFull ?
            $r('app.float.title_font_play') : $r('app.float.font_fourteen'))
          .fontColor($r('app.color.play_text_color'))
          .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
          .margin({ top: $r('app.float.music_text_margin_top') })
          .fontWeight(FontWeight.Regular)
      }
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph(this.isFavorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
        .fontSize(26)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .fontColor([this.isFavorite ? Color.Red : Color.White])
        .opacity(0.86)
        .onClick(() => {
          this.isFavorite = !this.isFavorite;
          AVSessionController.getInstance().updateFavoriteState(this.songList[this.selectIndex].bvid, this.isFavorite)
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
    .margin({ top: $r('app.float.music_info_margin_top') })
  }
}