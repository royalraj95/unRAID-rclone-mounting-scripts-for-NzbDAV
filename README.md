# unRAID rclone Mounting-Scripts for NzbDAV

Scripts to mount <a href="https://github.com/nzbdav-dev/nzbdav">NzbDAV</a> for unRAID users to allow maximum unattended usage and speed.

Collection of scripts to create rclone mounts of NzbDAV's WebDAV folder to be used efficiently by Plex (or Emby) for fast launches, and efficiently by your *arr apps. These scripts are intended for unRAID users, but should work for other platforms.

<h2>How it Works</h2>

NzbDAV will grab content from your usenet providers. These scripts allow this content to be added to your media library with *arrs treating it as local content allowing normal operation, and then streamed on demand via Plex. The default settings have this happening in RAM so no disk storage is needed. In theory this allows for an infinite library.

<h2>Key Functionality</h2>

- Continuously checks nzbdav mount and does health checks. If issues found attempts to fix and remount
- Includes optional steps to check if Decypharr has been mounted successfully. If issues found attempts to fix and remount
- "Primes" --dir-cache with new files to ensure that Plex launches superfast and arr operations are swift
- Includes optimised rclone settings for 1Gbps line with no disk caching, using RAM to buffer streams
- Includes the ability to stop or start Enabler (Dockers to start first that Worker dockers rely on), Consumer (Dockers that just need the mount to be active), and Worker dockers (Dockers that need the mount active and the Enabler Dockers up) to ensure dockers are set in optimal order
- Performs vital checks in Array Stop script to ensure a clean exit e.g. stopping dockers using Postgresql before stopping the Postgresql docker, exporting ZFS mounts etc

- Includes manual reset function if bad mount to help restore future mounts

<h2>Assumptions</h2>

<b>Required</b>

- You have a working installation of NzbDAV and it is setup to use as Import Strategy: "Symlinks - Plex", WebDAV enabled, and you have connected radarr and sonarr
- You have the User Scripts plugin installed on Unraid
- You have installed the rclone plugin on unRAID and have created a NZBDAV WebDAV remote e.g.

  <i>[nzb-dav]
  
  type = webdav
  
  url = http://172.17.0.1:3000
  
  vendor = other
  
  user = admin
  
  pass = redacted</i>

<b>Optional</b>
- You have also configured NzbDAV's "Rclone Server" tab. Recommended as it allows a higher --dir-cache setting
  
<h2>How to Use</h2>

1. Download the script files as raw and create two scripts via User Scripts
2. Set the <b>Array Stop</b> script to run at Array Stop and configure the script options in section 1 to match your server
3. Set the <b>Heartbeat</b> script to run on a cron e.g. every 3 mins so that it can automatically remount and ensure that your data is "primed" (see features above), and configure the options in section 1 to match your server
