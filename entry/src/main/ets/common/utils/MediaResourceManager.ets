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
import { APP_STORAGE_KEYS } from '../constants/AppStorageKeys';

const TAG = 'MediaResourceManager';

/**
 * 媒体资源管理器
 * 统一管理本地媒体资源：音频文件 (.m4a) 和封面图片 (.avif)
 * 文件结构：
 *   filesDir/media/
 *     ├── songs/      音频文件
 *     └── covers/     封面图片
 */
export class MediaResourceManager {
  private static instance: MediaResourceManager | undefined = undefined;

  // ============ 目录与扩展名常量 ============
  private readonly RESOURCE_ROOT = 'media';
  private readonly SONG_SUBDIR = 'songs';
  private readonly COVER_SUBDIR = 'covers';
  private readonly SONG_EXT = '.m4a';
  private readonly COVER_EXT = '.avif';
  private readonly PART_SUFFIX = '.part';

  // ============ 下载任务管理 ============
  private downloading: Map<string, Promise<void>> = new Map();

  // ============ 单例 ============
  public static getInstance(): MediaResourceManager {
    if (!MediaResourceManager.instance) {
      MediaResourceManager.instance = new MediaResourceManager();
    }
    return MediaResourceManager.instance;
  }

  // ============ Context 获取 ============
  private getContext(): common.UIAbilityContext | undefined {
    return AppStorage.get<common.UIAbilityContext>(APP_STORAGE_KEYS.CONTEXT);
  }

  // ============ 目录管理 ============
  /**
   * 获取媒体资源根目录
   */
  private getRootDir(): string {
    const context = this.getContext();
    if (!context) {
      Logger.error(TAG, 'Context is undefined');
      return '';
    }
    return `${context.filesDir}/${this.RESOURCE_ROOT}`;
  }

  /**
   * 获取子目录路径（如 songs/、covers/）
   */
  private getSubDir(subdir: string): string {
    const root = this.getRootDir();
    if (!root) return '';
    return `${root}/${subdir}`;
  }

  /**
   * 确保所有媒体子目录存在
   */
  private ensureDirectories(): void {
    const root = this.getRootDir();
    if (!root) return;
    try {
      fileIo.mkdirSync(root, true);
      fileIo.mkdirSync(this.getSubDir(this.SONG_SUBDIR), true);
      fileIo.mkdirSync(this.getSubDir(this.COVER_SUBDIR), true);
    } catch (e) {
      Logger.info(TAG, `mkdir result: ${e.message}`);
    }
  }

  // ============ 路径获取（公开） ============
  /**
   * 获取歌曲文件完整路径
   */
  public getSongPath(bvid: string): string {
    const dir = this.getSubDir(this.SONG_SUBDIR);
    return `${dir}/${bvid}${this.SONG_EXT}`;
  }

  /**
   * 获取封面文件完整路径
   */
  public getCoverPath(bvid: string): string {
    const dir = this.getSubDir(this.COVER_SUBDIR);
    return `${dir}/${bvid}${this.COVER_EXT}`;
  }

  // ============ 资源存在性检查 ============
  /**
   * 检查歌曲是否已下载
   */
  public hasSong(bvid: string): boolean {
    try {
      return fileIo.accessSync(this.getSongPath(bvid));
    } catch {
      return false;
    }
  }

  /**
   * 检查封面是否已下载
   */
  public hasCover(bvid: string): boolean {
    try {
      return fileIo.accessSync(this.getCoverPath(bvid));
    } catch {
      return false;
    }
  }

  // ============ 下载接口 ============
  /**
   * 下载歌曲（如果未下载且未在下载队列中）
   */
  public downloadSong(bvid: string, url: string): void {
    if (!bvid || !url) {
      Logger.warn(TAG, 'downloadSong: bvid or url is empty');
      return;
    }
    if (this.hasSong(bvid)) {
      Logger.debug(TAG, `Song ${bvid} already exists, skip download`);
      return;
    }
    if (this.downloading.has(bvid)) {
      Logger.debug(TAG, `Song ${bvid} is already downloading`);
      return;
    }

    this.ensureDirectories();
    const task = this.doDownloadSong(bvid, url);
    this.downloading.set(bvid, task);
    task
      .then(() => {
        this.downloading.delete(bvid);
        Logger.info(TAG, `Song ${bvid} downloaded successfully`);
      })
      .catch((err: Error) => {
        this.downloading.delete(bvid);
        Logger.error(TAG, `Song ${bvid} download failed: ${err.message}`);
      });
  }

  /**
   * 下载封面（如果未下载，静默执行，不阻塞主流程）
   */
  public async downloadCover(bvid: string, url: string): Promise<void> {
    if (!bvid || !url) {
      Logger.warn(TAG, 'downloadCover: bvid or url is empty');
      return;
    }
    if (this.hasCover(bvid)) {
      Logger.debug(TAG, `Cover ${bvid} already exists, skip download`);
      return;
    }

    this.ensureDirectories();
    return this.doDownloadCover(bvid, url)
      .then(() => Logger.info(TAG, `Cover ${bvid} downloaded successfully`))
      .catch((err: Error) => Logger.error(TAG, `Cover ${bvid} download failed: ${err.message}`));
  }

  // ============ 私有下载实现 ============
  /**
   * 下载歌曲（核心逻辑）
   */
  private async doDownloadSong(bvid: string, url: string): Promise<void> {
    const finalPath = this.getSongPath(bvid);
    const partPath = finalPath + this.PART_SUFFIX;

    // 清理残留文件
    this.removeFileQuietly(partPath);
    this.removeFileQuietly(finalPath);

    try {
      const buffer = await this.fetchBuffer(url, this.getSongHeaders());
      this.writeBufferToFile(partPath, buffer);
      fileIo.renameSync(partPath, finalPath);
    } catch (e) {
      this.removeFileQuietly(partPath);
      throw new Error(`Download song failed: ${e.message}`);
    }
  }

  /**
   * 下载封面（核心逻辑）
   */
  private async doDownloadCover(bvid: string, url: string): Promise<void> {
    const finalPath = this.getCoverPath(bvid);
    const partPath = finalPath + this.PART_SUFFIX;

    this.removeFileQuietly(partPath);
    this.removeFileQuietly(finalPath);

    try {
      const buffer = await this.fetchBuffer(url, this.getCoverHeaders());
      this.writeBufferToFile(partPath, buffer);
      fileIo.renameSync(partPath, finalPath);
    } catch (e) {
      this.removeFileQuietly(partPath);
      throw new Error(`Download cover failed: ${e.message}`);
    }
  }

  // ============ 网络请求 ============
  /**
   * 通用的获取 ArrayBuffer 方法
   */
  private async fetchBuffer(url: string, headers: Record<string, string>): Promise<ArrayBuffer> {
    const httpRequest = http.createHttp();
    let response: http.HttpResponse;
    try {
      response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
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
      throw new Error('Empty response body');
    }
    return buffer;
  }

  /**
   * 歌曲下载专用请求头
   */
  private getSongHeaders(): Record<string, string> {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Referer': 'https://www.bilibili.com/'
    };
  }

  /**
   * 封面下载专用请求头（更轻量）
   */
  private getCoverHeaders(): Record<string, string> {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    };
  }

  // ============ 文件写入 ============
  /**
   * 将 ArrayBuffer 写入文件
   */
  private writeBufferToFile(path: string, buffer: ArrayBuffer): void {
    const file = fileIo.openSync(
      path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
    );
    try {
      let written = 0;
      while (written < buffer.byteLength) {
        const count = fileIo.writeSync(file.fd, buffer.slice(written));
        if (count <= 0) {
          throw new Error('Write file failed: no bytes written');
        }
        written += count;
      }
    } finally {
      fileIo.closeSync(file);
    }
  }

  // ============ 删除操作 ============
  /**
   * 删除歌曲及其同名封面（如果有）
   */
  public removeSong(bvid: string): void {
    this.downloading.delete(bvid);
    this.removeFileQuietly(this.getSongPath(bvid));
    this.removeFileQuietly(this.getCoverPath(bvid));
    Logger.info(TAG, `Removed song and cover for ${bvid}`);
  }

  /**
   * 删除歌曲封面（如果有）
   */
  public removeCover(bvid: string): void {
    this.removeFileQuietly(this.getCoverPath(bvid));
    Logger.info(TAG, `Removed cover for ${bvid}`);
  }

  /**
   * 静默删除文件（不抛异常）
   */
  private removeFileQuietly(path: string): void {
    if (!path) return;
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch {
      // 忽略删除失败
    }
  }

  // ============ 批量清理 ============
  /**
   * 清理不在歌单中的孤儿资源（音频 + 封面）
   * 传入当前有效歌单，删除所有不在歌单中的 .m4a 和 .avif 文件
   */
  public cleanupOrphanResources(songList: SongItem[]): void {
    const validBvids = new Set<string>();
    for (const song of songList) {
      if (song.bvid) {
        validBvids.add(song.bvid);
      }
    }

    // 清理歌曲目录
    this.cleanupDirByExt(this.getSubDir(this.SONG_SUBDIR), this.SONG_EXT, validBvids);
    // 清理封面目录
    this.cleanupDirByExt(this.getSubDir(this.COVER_SUBDIR), this.COVER_EXT, validBvids);
  }

  /**
   * 清理指定目录下、指定扩展名、且 bvid 不在集合中的文件
   */
  private cleanupDirByExt(dir: string, ext: string, validBvids: Set<string>): void {
    if (!dir) return;
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      Logger.error(TAG, `List dir failed: ${e.message}`);
      return;
    }

    for (const name of names) {
      if (!name.endsWith(ext)) continue;
      const bvid = name.substring(0, name.length - ext.length);
      if (validBvids.has(bvid)) continue;
      try {
        this.removeFileQuietly(`${dir}/${name}`);
        Logger.info(TAG, `Deleted orphan: ${name}`);
      } catch (e) {
        Logger.error(TAG, `Delete ${name} failed: ${e.message}`);
      }
    }
  }
}