/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import Logger from './Logger';
import { SongItem } from '../../viewmodel/SongData';

const TAG = 'SongDownloadManager';
const SONG_DIR = 'songs';
const PART_SUFFIX = '.part';
const FINAL_EXT = '.m4a';

/**
 * 管理本地下载的歌曲文件。
 * 文件统一保存在应用沙箱 filesDir/songs 目录下，文件名就是 bvid.m4a
 * 下载流程：直接下载 .m4s 文件（纯音频）并重命名为 .m4a
 */
export class SongDownloadManager {
  private static instance: SongDownloadManager | undefined = undefined;
  private downloading: Map<string, Promise<void>> = new Map();

  public static getInstance(): SongDownloadManager {
    if (!SongDownloadManager.instance) {
      SongDownloadManager.instance = new SongDownloadManager();
    }
    return SongDownloadManager.instance;
  }

  private getContext(): common.UIAbilityContext | undefined {
    return AppStorage.get<common.UIAbilityContext>('context');
  }

  public getSongDir(): string {
    const context = this.getContext();
    if (!context) {
      Logger.error(TAG, 'context is undefined');
      return '';
    }
    return `${context.filesDir}/${SONG_DIR}`;
  }

  /**
   * 获取本地歌曲的完整路径（包含 .m4a 扩展名）
   */
  public getLocalPath(bvid: string): string {
    return `${this.getSongDir()}/${bvid}${FINAL_EXT}`;
  }

  public hasLocalSong(bvid: string): boolean {
    try {
      return fileIo.accessSync(this.getLocalPath(bvid));
    } catch (e) {
      return false;
    }
  }

  public removeLocalSong(bvid: string): void {
    this.removeFileQuietly(this.getLocalPath(bvid));
  }

  /**
   * 后台下载歌曲到本地。下载完成后，下次播放同名 bvid 时会直接使用本地文件。
   */
  public startDownload(bvid: string, url: string): void {
    if (!bvid || !url || this.hasLocalSong(bvid) || this.downloading.has(bvid)) {
      return;
    }
    const task = this.downloadToFile(bvid, url);
    this.downloading.set(bvid, task);
    task.then(() => {
      this.downloading.delete(bvid);
    }).catch((err: Error) => {
      this.downloading.delete(bvid);
      Logger.error(TAG, `download ${bvid} failed: ${err.message}`);
    });
  }

  /**
   * 下载 .m4s 文件，直接重命名为 .m4a（因为 .m4s 本质就是纯音频 MP4 片段）
   */
  private async downloadToFile(bvid: string, url: string): Promise<void> {
    const dir = this.ensureSongDir();
    const rawPath = `${dir}/${bvid}.m4s${PART_SUFFIX}`;   // 临时文件：.m4s.part
    const finalPath = `${dir}/${bvid}${FINAL_EXT}`;       // 最终文件：.m4a

    this.removeFileQuietly(rawPath);
    this.removeFileQuietly(finalPath);

    try {
      // 1. 下载原始 .m4s 数据到临时文件
      const buffer = await this.fetchAudioBuffer(bvid, url);
      this.writeBufferToFile(rawPath, buffer);

      // 2. 直接重命名为 .m4a
      fileIo.renameSync(rawPath, finalPath);

      Logger.info(TAG, `下载并重命名成功：${finalPath}`);
    } catch (e) {
      // 出错时清理所有相关文件
      this.removeFileQuietly(rawPath);
      this.removeFileQuietly(finalPath);
      throw new Error(`处理失败: ${e.message}`);
    }
  }

  private async fetchAudioBuffer(bvid: string, url: string): Promise<ArrayBuffer> {
    const httpRequest = http.createHttp();
    let response: http.HttpResponse;
    try {
      response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Referer': 'https://www.bilibili.com/'
        },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000,
        maxLimit: 100 * 1024 * 1024,
        maxRedirects: 5
      });
    } finally {
      httpRequest.destroy();
    }

    if (response.responseCode !== 200) {
      throw new Error(`HTTP error: ${response.responseCode}`);
    }
    const buffer = response.result as ArrayBuffer;
    if (!buffer || buffer.byteLength === 0) {
      throw new Error('empty audio file');
    }
    Logger.info(TAG, `downloading ${bvid}, size: ${buffer.byteLength}`);
    return buffer;
  }

  private writeBufferToFile(path: string, buffer: ArrayBuffer): void {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      let written = 0;
      while (written < buffer.byteLength) {
        const count = fileIo.writeSync(file.fd, buffer.slice(written));
        if (count <= 0) {
          throw new Error('write file failed');
        }
        written += count;
      }
    } finally {
      fileIo.closeSync(file);
    }
  }

  /**
   * 启动时调用：删除本地下载中已经不在收藏夹里的歌曲（包括未下载完成的 .part 临时文件）。
   */
  public deleteSongsNotIn(songList: SongItem[]): void {
    const validBvids = new Set<string>();
    for (const song of songList) {
      if (song.bvid) {
        validBvids.add(song.bvid);
      }
    }

    const dir = this.getSongDir();
    if (!dir) {
      return;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      Logger.error(TAG, `list song files failed: ${e.message}`);
      return;
    }

    for (const name of names) {
      let bvid = name;
      // 去除 .part 或 .m4a 后缀，还原为原始 bvid
      if (name.endsWith(PART_SUFFIX)) {
        bvid = name.substring(0, name.length - PART_SUFFIX.length);
      } else if (name.endsWith(FINAL_EXT)) {
        bvid = name.substring(0, name.length - FINAL_EXT.length);
      }
      // 如果无法解析出 bvid（例如其他文件），则跳过
      if (!bvid || bvid === name) {
        continue;
      }
      if (validBvids.has(bvid)) {
        continue;
      }
      try {
        fileIo.unlinkSync(`${dir}/${name}`);
        Logger.info(TAG, `deleted stale song file: ${name}`);
      } catch (e) {
        Logger.error(TAG, `delete ${name} failed: ${e.message}`);
      }
    }
  }

  private ensureSongDir(): string {
    const dir = this.getSongDir();
    if (!dir) {
      throw new Error('song dir is empty');
    }
    try {
      fileIo.mkdirSync(dir, true);
    } catch (e) {
      Logger.info(TAG, `mkdir result: ${e.message}`);
    }
    return dir;
  }

  private removeFileQuietly(path: string): void {
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
  }
}