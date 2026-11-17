/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { MediaDownloadWriter } from './MediaDownloadWriter';
import Logger from './Logger';
import { SongItem } from '../../viewmodel/SongData';
import { APP_STORAGE_KEYS } from '../constants/AppStorageKeys';

const TAG = 'MediaResourceManager';

interface CacheEntry {
  bvid: string;
  path: string;
  size: number;
  lastAccessAt: number;
}

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
  private downloadingSongs: Map<string, Promise<void>> = new Map();
  private downloadingCovers: Map<string, Promise<void>> = new Map();
  private resourceVersions: Map<string, number> = new Map();
  private activeDownloadCancels: Map<string, () => void> = new Map();
  private activeSongBvid: string | undefined = undefined;
  private transitionSongBvid: string | undefined = undefined;
  private readonly cacheAccessTimes: Map<string, number> = new Map();
  private readonly cacheMtimePersistedAt: Map<string, number> = new Map();
  private static readonly MAX_SONG_CACHE_BYTES: number = 512 * 1024 * 1024;
  private static readonly MAX_COVER_CACHE_BYTES: number = 96 * 1024 * 1024;
  private static readonly STALE_PART_MAX_AGE_MS: number = 24 * 60 * 60 * 1000;
  private static readonly CACHE_MTIME_WRITE_INTERVAL_MS: number = 5 * 60 * 1000;

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
  private ensureDirectory(path: string): void {
    if (!path) return;
    try {
      if (fileIo.accessSync(path)) {
        return;
      }
    } catch {
      // A missing path is created below; creation errors are logged by caller.
    }
    fileIo.mkdirSync(path, true);
  }

  private ensureDirectories(): void {
    const directories = [
      this.getRootDir(),
      this.getSubDir(this.SONG_SUBDIR),
      this.getSubDir(this.COVER_SUBDIR)
    ];
    for (const directory of directories) {
      try {
        this.ensureDirectory(directory);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `Failed to ensure media directory '${directory}': ${message}`);
      }
    }
  }

  // ============ 路径获取（公开） ============
  /**
   * 获取歌曲文件完整路径
   */
  private isValidBvid(bvid: string): boolean {
    return /^[A-Za-z0-9_-]+$/.test(bvid) && bvid !== '.' && bvid !== '..';
  }

  private getResourceVersion(key: string): number {
    return this.resourceVersions.get(key) ?? 0;
  }

  private isResourceVersionCurrent(key: string, version: number): boolean {
    return this.getResourceVersion(key) === version;
  }

  private nextResourceVersion(key: string): number {
    const version = this.getResourceVersion(key) + 1;
    this.resourceVersions.set(key, version);
    return version;
  }

  private invalidateResource(key: string): void {
    this.nextResourceVersion(key);
    const cancel = this.activeDownloadCancels.get(key);
    if (cancel) {
      this.activeDownloadCancels.delete(key);
      cancel();
    }
  }

  public getSongPath(bvid: string): string {
    if (!this.isValidBvid(bvid)) {
      return '';
    }
    const dir = this.getSubDir(this.SONG_SUBDIR);
    return dir ? `${dir}/${bvid}${this.SONG_EXT}` : '';
  }

  /**
   * 获取封面文件完整路径
   */
  public getCoverPath(bvid: string): string {
    if (!this.isValidBvid(bvid)) {
      return '';
    }
    const dir = this.getSubDir(this.COVER_SUBDIR);
    return dir ? `${dir}/${bvid}${this.COVER_EXT}` : '';
  }

  // ============ 资源存在性检查 ============
  /**
   * 检查歌曲是否已下载
   */
  public hasSong(bvid: string): boolean {
    const path = this.getSongPath(bvid);
    if (!path) {
      return false;
    }
    try {
      const exists = fileIo.accessSync(path);
      if (exists) {
        this.recordCacheAccess(`song:${bvid}`, path);
      }
      return exists;
    } catch {
      return false;
    }
  }

  /**
   * 检查封面是否已下载
   */
  public hasCover(bvid: string): boolean {
    const path = this.getCoverPath(bvid);
    if (!path) {
      return false;
    }
    try {
      const exists = fileIo.accessSync(path);
      if (exists) {
        this.recordCacheAccess(`cover:${bvid}`, path);
      }
      return exists;
    } catch {
      return false;
    }
  }

  /** Protect the current track from LRU eviction and clear any old transition candidate. */
  public setActiveSong(bvid: string | undefined): void {
    this.activeSongBvid = bvid && this.isValidBvid(bvid) ? bvid : undefined;
    this.transitionSongBvid = undefined;
  }

  /** Keep the previous active track and only the latest candidate safe during a transition. */
  public protectSongForTransition(bvid: string): void {
    this.transitionSongBvid = this.isValidBvid(bvid) ? bvid : undefined;
  }

  private isSongProtected(bvid: string): boolean {
    return bvid === this.activeSongBvid || bvid === this.transitionSongBvid;
  }

  private forgetCacheAccess(resourceType: string, bvid: string): void {
    const resourceKey = `${resourceType}:${bvid}`;
    this.cacheAccessTimes.delete(resourceKey);
    this.cacheMtimePersistedAt.delete(resourceKey);
  }

  private recordCacheAccess(resourceKey: string, path: string): void {
    const accessedAt = Date.now();
    this.cacheAccessTimes.set(resourceKey, accessedAt);
    const lastPersistedAt = this.cacheMtimePersistedAt.get(resourceKey) ?? 0;
    if (accessedAt - lastPersistedAt < MediaResourceManager.CACHE_MTIME_WRITE_INTERVAL_MS) {
      return;
    }
    try {
      // HarmonyOS user-data partitions may mount with noatime, so persist LRU
      // recency through mtime instead of relying on Stat.atime after restart.
      // Throttle metadata writes to avoid touching the file on every cache hit.
      fileIo.utimes(path, accessedAt);
      this.cacheMtimePersistedAt.set(resourceKey, accessedAt);
    } catch {
      // Avoid retrying a failed metadata update on every cache lookup.
      // The in-memory timestamp still provides accurate LRU ordering this run.
      this.cacheMtimePersistedAt.set(resourceKey, accessedAt);
    }
  }

  // ============ 下载接口 ============
  /**
   * 下载歌曲（如果未下载且未在下载队列中）
   */
  public downloadSong(bvid: string, url: string): void {
    if (!this.isValidBvid(bvid) || !url) {
      Logger.warn(TAG, 'downloadSong skipped: invalid bvid or empty URL');
      return;
    }
    if (this.hasSong(bvid)) {
      Logger.debug(TAG, `Song ${bvid} already exists, skip download`);
      return;
    }
    if (this.downloadingSongs.has(bvid)) {
      Logger.debug(TAG, `Song ${bvid} is already downloading`);
      return;
    }

    this.ensureDirectories();
    const resourceVersion = this.nextResourceVersion(`song:${bvid}`);
    const task = this.doDownloadSong(bvid, url, resourceVersion);
    this.downloadingSongs.set(bvid, task);
    task
      .then(() => {
        if (this.hasSong(bvid)) {
          Logger.info(TAG, `Song ${bvid} downloaded successfully`);
        }
      })
      .catch((error: Error) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.error(TAG, `Song ${bvid} download failed: ${message}`);
      })
      .finally(() => {
        if (this.downloadingSongs.get(bvid) === task) {
          this.downloadingSongs.delete(bvid);
          this.cleanupCacheByLimit();
        }
      });
  }

  /**
   * 下载封面（如果未下载，静默执行，不阻塞主流程）
   */
  public async downloadCover(bvid: string, url: string): Promise<void> {
    if (!this.isValidBvid(bvid) || !url) {
      Logger.warn(TAG, 'downloadCover skipped: invalid bvid or empty URL');
      return;
    }
    if (this.hasCover(bvid)) {
      Logger.debug(TAG, `Cover ${bvid} already exists, skip download`);
      return;
    }
    const existingTask = this.downloadingCovers.get(bvid);
    if (existingTask) {
      return existingTask;
    }

    this.ensureDirectories();
    const resourceVersion = this.nextResourceVersion(`cover:${bvid}`);
    const task = this.doDownloadCover(bvid, url, resourceVersion);
    this.downloadingCovers.set(bvid, task);
    try {
      await task;
      if (this.hasCover(bvid)) {
        Logger.info(TAG, `Cover ${bvid} downloaded successfully`);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Cover ${bvid} download failed: ${message}`);
    } finally {
      if (this.downloadingCovers.get(bvid) === task) {
        this.downloadingCovers.delete(bvid);
        this.cleanupCacheByLimit();
      }
    }
  }

  // ============ 私有下载实现 ============
  /** 下载歌曲并发布到正式缓存路径。 */
  private async doDownloadSong(bvid: string, url: string, resourceVersion: number): Promise<void> {
    await this.downloadResource(
      this.getSongPath(bvid),
      url,
      this.getSongHeaders(),
      `song:${bvid}`,
      resourceVersion,
      'song'
    );
  }

  /** 下载封面并发布到正式缓存路径。 */
  private async doDownloadCover(bvid: string, url: string, resourceVersion: number): Promise<void> {
    await this.downloadResource(
      this.getCoverPath(bvid),
      url,
      this.getCoverHeaders(),
      `cover:${bvid}`,
      resourceVersion,
      'cover'
    );
  }

  /**
   * 歌曲和封面共用同一套下载、版本校验和临时文件发布流程。
   * 类型差异只保留在目标路径、请求头和日志标签中。
   */
  private async downloadResource(
    finalPath: string,
    url: string,
    headers: Record<string, string>,
    resourceKey: string,
    resourceVersion: number,
    resourceType: string
  ): Promise<void> {
    if (!finalPath) {
      throw new Error(`Invalid ${resourceType} resource path`);
    }

    const partPath = `${finalPath}.${resourceVersion}${this.PART_SUFFIX}`;
    try {
      await this.downloadToFile(url, headers, partPath, resourceKey, resourceVersion);
      if (!this.isResourceVersionCurrent(resourceKey, resourceVersion)) {
        this.removeFileQuietly(partPath);
        return;
      }
      this.validateDownloadedPayload(partPath, resourceType);

      // Never delete a previously published cache before the new file is ready.
      // If another task has already populated the target, keep that file.
      if (this.pathExists(finalPath)) {
        this.removeFileQuietly(partPath);
        Logger.info(TAG, `Keeping existing ${resourceType} cache: ${finalPath}`);
        return;
      }
      fileIo.renameSync(partPath, finalPath);
    } catch (error) {
      this.removeFileQuietly(partPath);
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`Download ${resourceType} failed: ${message}`);
    }
  }

  // ============ 下载执行 ============
  /**
   * Reject common textual CDN/error payloads before publishing them as media.
   * This deliberately avoids enforcing one codec/container signature because
   * Bilibili may return different valid media variants over time.
   */
  private validateDownloadedPayload(path: string, resourceType: string): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(64);
      const bytesRead = fileIo.readSync(file.fd, buffer, { length: 64 });
      if (bytesRead <= 0) {
        throw new Error(`Downloaded ${resourceType} is empty`);
      }

      const bytes = new Uint8Array(buffer, 0, bytesRead);
      let prefix = '';
      for (let index = 0; index < bytesRead; index++) {
        prefix += String.fromCharCode(bytes[index]);
      }
      prefix = prefix.replace(/^\s+/, '').toLowerCase();
      const errorPrefixes = [
        '<!doctype',
        '<html',
        '<?xml',
        '{',
        '[',
        'access denied',
        'forbidden',
        'bad gateway',
        'service unavailable'
      ];
      if (errorPrefixes.some((marker: string) => prefix.startsWith(marker))) {
        throw new Error(`Downloaded ${resourceType} contains a textual error response`);
      }
    } finally {
      fileIo.closeSync(file);
    }
  }

  private pathExists(path: string): boolean {
    if (!path) {
      return false;
    }
    try {
      return fileIo.accessSync(path);
    } catch {
      return false;
    }
  }

  private async downloadToFile(
    url: string,
    headers: Record<string, string>,
    path: string,
    resourceKey: string,
    resourceVersion: number
  ): Promise<void> {
    let registeredCancel: (() => void) | undefined;
    try {
      await MediaDownloadWriter.download(
        url,
        headers,
        path,
        () => this.isResourceVersionCurrent(resourceKey, resourceVersion),
        (cancel) => {
          if (cancel) {
            registeredCancel = cancel;
            this.activeDownloadCancels.set(resourceKey, cancel);
          } else if (registeredCancel &&
            this.activeDownloadCancels.get(resourceKey) === registeredCancel) {
            this.activeDownloadCancels.delete(resourceKey);
          }
        }
      );
    } finally {
      if (registeredCancel && this.activeDownloadCancels.get(resourceKey) === registeredCancel) {
        this.activeDownloadCancels.delete(resourceKey);
      }
    }
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

  // ============ 删除操作 ============
  /**
   * 删除本地音频文件，并使同一歌曲正在执行的下载任务失效。
   */
  public removeSongFile(bvid: string): void {
    if (!this.isValidBvid(bvid)) {
      return;
    }
    this.invalidateResource(`song:${bvid}`);
    this.downloadingSongs.delete(bvid);
    this.forgetCacheAccess('song', bvid);
    const songPath = this.getSongPath(bvid);
    if (songPath) {
      this.removeFileQuietly(songPath);
      this.removePartFiles(songPath);
    }
    Logger.info(TAG, `Removed song file for ${bvid}`);
  }

  /**
   * 删除歌曲封面（如果有）
   */
  public removeCover(bvid: string): void {
    if (!this.isValidBvid(bvid)) {
      return;
    }
    this.invalidateResource(`cover:${bvid}`);
    this.downloadingCovers.delete(bvid);
    this.forgetCacheAccess('cover', bvid);
    const coverPath = this.getCoverPath(bvid);
    if (coverPath) {
      this.removeFileQuietly(coverPath);
      this.removePartFiles(coverPath);
    }
    Logger.info(TAG, `Removed cover for ${bvid}`);
  }

  private removePartFiles(resourcePath: string): void {
    const dir = resourcePath.substring(0, resourcePath.lastIndexOf('/'));
    const filePrefix = resourcePath.substring(resourcePath.lastIndexOf('/') + 1) + '.';
    if (!dir) {
      return;
    }
    try {
      for (const name of fileIo.listFileSync(dir)) {
        if (name.startsWith(filePrefix) && name.endsWith(this.PART_SUFFIX)) {
          this.removeFileQuietly(`${dir}/${name}`);
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Failed to list temporary files: ${message}`);
    }
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
    this.ensureDirectories();
    const validBvids = new Set<string>();
    for (const song of songList) {
      if (this.isValidBvid(song.bvid)) {
        validBvids.add(song.bvid);
      }
    }

    // Keep the active/transitioning track even if it has just disappeared
    // from the refreshed playlist. The player may still be reading its file.
    if (this.activeSongBvid) {
      validBvids.add(this.activeSongBvid);
    }
    if (this.transitionSongBvid) {
      validBvids.add(this.transitionSongBvid);
    }

    // Invalidate old requests before deleting orphan files so late responses
    // cannot publish resources after the cleanup pass.
    this.invalidateOrphanDownloads(this.downloadingSongs, validBvids, 'song');
    this.invalidateOrphanDownloads(this.downloadingCovers, validBvids, 'cover');

    // 清理歌曲目录
    this.cleanupDirByExt(this.getSubDir(this.SONG_SUBDIR), this.SONG_EXT, validBvids);
    // 清理封面目录
    this.cleanupDirByExt(this.getSubDir(this.COVER_SUBDIR), this.COVER_EXT, validBvids);
    this.cleanupCacheByLimit();
  }

  /**
   * Enforce independent LRU budgets for songs and covers.
   * The currently loaded song and in-flight downloads are never evicted.
   * Call on startup, after downloads, and when the ability enters background.
   */
  public cleanupCacheByLimit(): void {
    this.ensureDirectories();
    this.cleanupStalePartFiles(this.getSubDir(this.SONG_SUBDIR), this.SONG_EXT, 'song');
    this.cleanupStalePartFiles(this.getSubDir(this.COVER_SUBDIR), this.COVER_EXT, 'cover');
    this.pruneCacheDirectory(
      this.getSubDir(this.SONG_SUBDIR),
      this.SONG_EXT,
      'song',
      MediaResourceManager.MAX_SONG_CACHE_BYTES
    );
    this.pruneCacheDirectory(
      this.getSubDir(this.COVER_SUBDIR),
      this.COVER_EXT,
      'cover',
      MediaResourceManager.MAX_COVER_CACHE_BYTES
    );
  }


  /** Remove abandoned partial downloads older than 24 hours; never touch active tasks. */
  private cleanupStalePartFiles(dir: string, extension: string, resourceType: string): void {
    if (!dir) {
      return;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch {
      return;
    }

    const downloads = resourceType === 'song' ? this.downloadingSongs : this.downloadingCovers;
    const now = Date.now();
    for (const name of names) {
      if (!name.endsWith(this.PART_SUFFIX)) {
        continue;
      }
      const temporaryName = name.substring(0, name.length - this.PART_SUFFIX.length);
      const versionSeparator = temporaryName.lastIndexOf('.');
      if (versionSeparator <= 0 || !/^\d+$/.test(temporaryName.substring(versionSeparator + 1))) {
        continue;
      }
      const resourceName = temporaryName.substring(0, versionSeparator);
      if (!resourceName.endsWith(extension)) {
        continue;
      }
      const bvid = resourceName.substring(0, resourceName.length - extension.length);
      if (!this.isValidBvid(bvid)) {
        continue;
      }
      const version = Number(temporaryName.substring(versionSeparator + 1));
      const resourceKey = `${resourceType}:${bvid}`;
      if (downloads.has(bvid) && this.isResourceVersionCurrent(resourceKey, version)) {
        continue;
      }

      const path = `${dir}/${name}`;
      try {
        const modifiedAt = Number(fileIo.statSync(path).mtime) * 1000;
        if (modifiedAt > 0 && now - modifiedAt >= MediaResourceManager.STALE_PART_MAX_AGE_MS) {
          this.removeFileQuietly(path);
        }
      } catch {
        // Ignore files that disappear during the scan or cannot be stat'ed.
      }
    }
  }

  private pruneCacheDirectory(
    dir: string,
    extension: string,
    resourceType: string,
    maxBytes: number
  ): void {
    if (!dir) {
      return;
    }

    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Cache scan failed (${resourceType}): ${message}`);
      return;
    }

    const entries: CacheEntry[] = [];
    let totalBytes = 0;
    for (const name of names) {
      if (!name.endsWith(extension) || name.endsWith(this.PART_SUFFIX)) {
        continue;
      }
      const bvid = name.substring(0, name.length - extension.length);
      if (!this.isValidBvid(bvid)) {
        continue;
      }
      const path = `${dir}/${name}`;
      try {
        const stat = fileIo.statSync(path);
        const size = Math.max(0, stat.size);
        const accessKey = `${resourceType}:${bvid}`;
        // utimes() writes the last cache hit into mtime in milliseconds; Stat
        // reports mtime in seconds. atime is not used because HarmonyOS user
        // data partitions may be mounted with noatime.
        const fileAccessTime = Number(stat.mtime) * 1000 || 0;
        const lastAccessAt = this.cacheAccessTimes.get(accessKey) ?? fileAccessTime;
        entries.push({ bvid, path, size, lastAccessAt });
        totalBytes += size;
      } catch {
        // An unreadable cache entry is ignored; normal playback recovery can
        // remove/refetch it if it is selected later.
      }
    }

    if (totalBytes <= maxBytes) {
      return;
    }

    entries.sort((left: CacheEntry, right: CacheEntry) => left.lastAccessAt - right.lastAccessAt);
    let removedCount = 0;
    let freedBytes = 0;
    for (const entry of entries) {
      if (totalBytes <= maxBytes) {
        break;
      }
      const isActiveDownload = resourceType === 'song'
        ? this.downloadingSongs.has(entry.bvid)
        : this.downloadingCovers.has(entry.bvid);
      if (this.isSongProtected(entry.bvid) || isActiveDownload) {
        continue;
      }

      this.removeFileQuietly(entry.path);
      if (!this.pathExists(entry.path)) {
        totalBytes -= entry.size;
        freedBytes += entry.size;
        removedCount++;
        this.forgetCacheAccess(resourceType, entry.bvid);
      }
    }

    if (removedCount > 0) {
      Logger.info(
        TAG,
        `Cache LRU cleanup (${resourceType}): removed=${removedCount} freedBytes=${freedBytes} remainingBytes=${Math.max(0, totalBytes)} limitBytes=${maxBytes}`
      );
    }
    if (totalBytes > maxBytes) {
      Logger.warn(
        TAG,
        `Cache remains above limit (${resourceType}); protected or undeletable files remain: remainingBytes=${totalBytes} limitBytes=${maxBytes}`
      );
    }
  }

  private invalidateOrphanDownloads(
    downloads: Map<string, Promise<void>>,
    validBvids: Set<string>,
    resourceType: string
  ): void {
    for (const bvid of downloads.keys()) {
      if (!validBvids.has(bvid)) {
        this.invalidateResource(`${resourceType}:${bvid}`);
        downloads.delete(bvid);
      }
    }
  }

  /**
   * 清理指定目录下、指定扩展名、且 bvid 不在集合中的文件
   */
  private cleanupDirByExt(dir: string, ext: string, validBvids: Set<string>): void {
    if (!dir) return;
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `List dir failed: ${message}`);
      return;
    }

    for (const name of names) {
      if (name.endsWith(this.PART_SUFFIX)) {
        const tempName = name.substring(0, name.length - this.PART_SUFFIX.length);
        const versionSeparator = tempName.lastIndexOf('.');
        if (versionSeparator > 0 && /^\d+$/.test(tempName.substring(versionSeparator + 1))) {
          const resourceName = tempName.substring(0, versionSeparator);
          if (resourceName.endsWith(ext)) {
            const partBvid = resourceName.substring(0, resourceName.length - ext.length);
            const key = ext === this.SONG_EXT ? `song:${partBvid}` : `cover:${partBvid}`;
            const version = Number(tempName.substring(versionSeparator + 1));
            const isActiveDownload = ext === this.SONG_EXT
              ? this.downloadingSongs.has(partBvid)
              : ext === this.COVER_EXT && this.downloadingCovers.has(partBvid);

            if (this.isValidBvid(partBvid) && validBvids.has(partBvid) && isActiveDownload &&
              this.isResourceVersionCurrent(key, version)) {
              continue;
            }
          }
        }
        this.removeFileQuietly(`${dir}/${name}`);
        continue;
      }
      if (!name.endsWith(ext)) continue;
      const bvid = name.substring(0, name.length - ext.length);
      if (validBvids.has(bvid)) continue;
      try {
        this.removeFileQuietly(`${dir}/${name}`);
        this.forgetCacheAccess(ext === this.SONG_EXT ? 'song' : 'cover', bvid);
        Logger.info(TAG, `Deleted orphan: ${name}`);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.error(TAG, `Delete ${name} failed: ${message}`);
      }
    }
  }
}
