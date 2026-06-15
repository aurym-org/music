/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { ContentConstants } from '../common/constants/ContentConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { BreakpointType } from '../common/utils/BreakpointSystem';
import Logger from '../common/utils/Logger';
import { SongItem } from '../viewmodel/SongData';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';

const TAG = 'PlaylistControl';

@Component
export struct PlaylistControl {
  @StorageProp('songList') @Watch('onSongListChange') songList: SongItem[] = [];
  @StorageProp('currentBreakpoint') currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp('selectIndex') selectIndex: number = 0;
  @StorageProp('isPlay') isPlay: boolean = false;
  @State isShowSheet: boolean = false;
  @State searchKeyword: string = '';
  @State filteredIndices: number[] = [];
  private scroller: Scroller = new Scroller();

  private onSongListChange(): void {
    this.applyFilter();
  }

  private applyFilter(): void {
    const keyword = this.searchKeyword.toLowerCase().trim();
    if (!keyword) {
      this.filteredIndices = this.songList.map((_, i) => i);
    } else {
      const result: number[] = [];
      this.songList.forEach((item, i) => {
        if (item.title.toLowerCase().includes(keyword) ||
            item.singer.toLowerCase().includes(keyword)) {
          result.push(i);
        }
      });
      this.filteredIndices = result;
    }
    this.scroller.scrollToIndex(0);
  }

  build() {
    SymbolGlyph($r('sys.symbol.music_note_list'))
      .fontSize(26)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .fontColor([Color.White])
      .opacity(0.86)
      .onClick(() => {
        this.isShowSheet = true;
      })
      .bindSheet($$this.isShowSheet, this.playlistSheet(), {
        detents: [SheetSize.MEDIUM],
        dragBar: false,
        showClose: false,
        preferType: SheetType.CENTER,
        onWillAppear: () => {
          Logger.info(TAG, 'playlist sheet appearing');
          this.scroller.scrollToIndex(this.selectIndex, false, ScrollAlign.CENTER);
        },
        onWillDismiss: () => {
          this.isShowSheet = false;
          this.searchKeyword = '';
          this.applyFilter();
        }
      })
  }

  @Builder
  playlistSheet() {
    Column() {
      this.playListTitle()
      Search({ placeholder: '搜索歌曲', value: this.searchKeyword })
        .textFont({ size: 14 })
        .height(36)
        .borderRadius(8)
        .margin({
          top: $r('app.float.list_area_margin_top'),
          left: $r('app.float.list_item_padding'),
          right: $r('app.float.list_item_padding'),
          bottom: $r('app.float.list_item_padding')
        })
        .onChange((value: string) => {
          this.searchKeyword = value;
          this.applyFilter();
        })
      List({ scroller: this.scroller }) {
        ForEach(this.filteredIndices, (globalIndex: number) => {
          ListItem() {
            PlayListContainer({
              item: this.songList[globalIndex],
              index: globalIndex,
              isPlay: this.isPlay,
              selectIndex: this.selectIndex
            })
          }
        }, (globalIndex: number) => this.songList[globalIndex].bvid)
      }
      .height(StyleConstants.FULL_HEIGHT)
      .width(StyleConstants.FULL_WIDTH)
      .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
      .margin({ top: $r('app.float.list_item_padding') })
      .lanes(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG ?
        ContentConstants.COL_TWO : ContentConstants.COL_ONE)
      .layoutWeight(1)
      .divider({
        color: $r('sys.color.ohos_id_color_list_separator'),
        strokeWidth: $r('app.float.stroke_width'),
        startMargin: $r('app.float.list_item_padding'),
        endMargin: $r('app.float.list_item_padding')
      })
    }
    .padding({
      top: this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM ? 0 : $r('app.float.list_area_padding_top'),
      bottom: $r('app.float.list_area_padding_bottom')
    })
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
  }

  @Builder
  playListTitle() {
    Row() {
      Image($r('app.media.ic_sort_list'))
        .height($r('app.float.play_all_icon_size'))
        .width($r('app.float.play_all_icon_size'))
        .fillColor($r('sys.color.ohos_id_color_text_primary'))
      Text($r('app.string.play_list', this.songList.length))
        .maxLines(ContentConstants.PLAY_ALL_MAX_LINES)
        .padding({ left: $r('app.float.play_all_text_padding') })
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .fontSize(new BreakpointType({
          sm: $r('app.float.play_font_sm'),
          md: $r('app.float.play_font_md'),
          lg: $r('app.float.play_font_lg')
        }).getValue(this.currentBreakpoint))
    }
    .height($r('app.float.play_all_area_height'))
    .width(StyleConstants.FULL_WIDTH)
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
    .padding({
      left: $r('app.float.play_all_area_padding'),
      right: $r('app.float.play_all_area_padding')
    })
    .borderRadius({
      topRight: $r('app.float.play_all_border_radius'),
      topLeft: $r('app.float.play_all_border_radius')
    })
    .position({ x: 0, y: 0 })
  }
}

@Component
struct PlayListContainer {
  @Prop isPlay: boolean = false;
  @StorageProp('currentBreakpoint') currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @Prop selectIndex: number = 0;
  @Prop item: SongItem = new SongItem();
  @Prop index: number = 0;

  build() {
    Column() {
      Row() {
        if (this.selectIndex === this.index) {
          Image(this.isPlay ? $r('app.media.ic_wave') : $r('app.media.ic_wave_static'))
            .width($r("app.float.wave_width"))
            .height($r("app.float.wave_height"))
        }
        Column() {
          Text(this.item.title)
            .fontColor(this.selectIndex === this.index ? $r('sys.color.ohos_id_color_badge_red') : $r('sys.color.ohos_id_color_text_primary'))
            .fontSize(new BreakpointType({
              sm: $r('app.float.item_font_sm'),
              md: $r('app.float.item_font_md'),
              lg: $r('app.float.item_font_lg')
            }).getValue(this.currentBreakpoint))
            .margin({ bottom: $r('app.float.list_item_title_margin') })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Text(this.item.singer)
              .opacity($r('app.float.singer_opacity'))
              .fontColor(this.selectIndex === this.index ? $r('sys.color.ohos_id_color_badge_red') : $r('sys.color.ohos_id_color_text_primary'))
              .fontSize(new BreakpointType({
                sm: $r('app.float.singer_title_sm'),
                md: $r('app.float.singer_title_md'),
                lg: $r('app.float.singer_title_lg')
              }).getValue(this.currentBreakpoint))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .onClick(() => {
        if (this.selectIndex === this.index && this.isPlay) {
          MediaControlCenter.getInstance().pause();
        } else {
          MediaControlCenter.getInstance().switchToIndex(this.index!);
        }
      })
      .height($r('app.float.list_item_height'))
      .width(StyleConstants.FULL_WIDTH)
    }
    .padding({
      left: $r('app.float.list_item_padding'),
      right: $r('app.float.list_item_padding')
    })
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
  }
}