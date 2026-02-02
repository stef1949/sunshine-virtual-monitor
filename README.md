<h1 align='center'>Sunshine Virtual Monitor</h1>
<p align="center">
 Sunshine Virtual Monitor provides a way to automatically enable a <b>dedicated Virtual Display Monitor</b> for your Sunshine Streaming Sessions.
 <br>
  It keeps your normal display active and <b>adds the virtual display as an extended monitor</b> while streaming, then restores your previous layout when the stream ends.
  </p>

# Table of Contents
- [Disclaimer](#disclaimer)
- [What This Does](#what-this-does)
- [Setup](#setup)
    - [Prerequisites](#prerequisites)
    - [Virtual Display Driver](#virtual-display-driver)
    - [Multi Monitor Tool](#multi-monitor-tool)
    - [Windows Display Manager](#windows-display-manager)
    - [VSYNC Toggle](#vsync-toggle)
    - [Scripts Directory Files](#scripts-directory-files)
- [Sunshine Setup](#sunshine-setup)
    - [Option 1 - UI](#option-1---ui)
    - [Option 2 - Config File](#option-2---config-file)

## Disclaimer

> [!CAUTION]
> This should be considered **BETA** - it is working well for me, but at the time of writing this no one else has tested it so far.

While I'm pretty confident this will not break your computer, I don't know enough about Windows drivers to be 100% sure. Further, there is a real risk that your display layout won't restore properly after a streaming session if there is some issue with Sunshine or the scripts.

If something goes wrong, you can escape in a few ways:

- If your displays don't come back, but Sunshine is still running, you can get back in the stream and fix things up:
    - Run this command from a privileged terminal to disable the virtual display device:

    ```batch
    pnputil /disable-device /deviceid root\iddsampledriver
    ```

> [!NOTE]
>
> If you want to be extra secure you can try to bind this command to some key combination ahead of time (make sure it runs as admin).
>
> To do this, create a new shortcut on Desktop (`Right Click` > `New` > `Shortcut`) and copy/paste the command above (`pnputil /disable-device /deviceid root\iddsampledriver`) in the path box.
>
> Give it a name like `Disable Virtual Display Driver` and close the window. Now go to the file properties and click in the `Shortcut Key` area, then enter a combination of keys to create the shortcut. (e.g. `Ctrl` + `Alt` + `5`)
>
> Open the `Advanced...` box and check the `Run as administrator` checkbox.
>
> Save and close.

- If you can't access the Sunshine stream for whatever reason, you can try a couple of things:
    - Open a Windows Terminal and run:
    ```batch
    DisplaySwitch /internal
    ```

> [!NOTE]
> This forces Windows to use only your internal/primary physical display. This is often enough to regain control if Windows ends up applying a bad layout.

- Press Windows + P to open the projection menu, then select PC screen only or Extend. I recommend practicing this ahead of time if you want to go this route.
- Connect another display to your computer - this may force Windows to re-evaluate the display layout and restore signal to a physical display.
- If you already have a second physical monitor, disconnect/reconnect it - similar to the point above, it can trigger a layout rebuild.

## What This Does

During a Sunshine session:

- Enables the virtual display device
- Forces Windows to use Extend (physical + virtual)
- Optionally sets the virtual display as primary for the stream
- Restores the previous display layout when the session ends

## Setup

First, download the [latest release](https://github.com/Cynary/sunshine-virtual-monitor/releases/latest) (`.zip` file) and unzip it.

### Prerequisites

- Windows 10/11
- Sunshine already installed and working
- Admin access (for enabling/disabling the virtual display device)

### Virtual Display Driver

Then, you'll need to add a virtual display to your computer. You can follow the directions from [Virtual Display Driver](https://github.com/itsmikethetech/Virtual-Display-Driver?tab=readme-ov-file#virtual-display-driver) - afaict, this is the only way to get HDR support on a virtual monitor. Note: while the driver and device will exist, they will be disabled while Sunshine isn't being used.

Once you're done adding the device, make sure to disable it. You can do this in Device Manager, or you can run the following command in an administrator terminal:

```batch
pnputil /disable-device /deviceid root\iddsampledriver
```

### Multi Monitor Tool

Then, you'll need to download [MultiMonitorTool](https://www.nirsoft.net/utils/multi_monitor_tool.html) - make sure to place the extracted files in the same directory as the scripts. These scripts assume that the multi-monitor tool in use is the 64-bit version. If you need the 32-bit version, you'll need to edit this line for the correct path:

```batch
$multitool = Join-Path -Path $filePath -ChildPath "multimonitortool-x64\MultiMonitorTool.exe"
```

### Windows Display Manager

The PowerShell scripts use a module called [`WindowsDisplayManager`](https://github.com/patrick-theprogrammer/WindowsDisplayManager) - you can install this by starting a privileged PowerShell, and running:

```batch
Install-Module -Name WindowsDisplayManager
```

### VSYNC Toggle

This is used to turn off / restore vsync when the stream starts/ends.

Just download [vsync-toggle](https://github.com/xanderfrangos/vsync-toggle/releases/latest) and put it in the same directory as the scripts.

### Scripts Directory Files

After the steps above, the scripts directory will look like this:

```
LICENSE
multimonitortool-x64/
README.md
setup_sunvdm.ps1
teardown_sunvdm.ps1
vsynctoggle-1.1.0-x86_64.exe
```

## Sunshine Setup

In all the text below, replace `%PATH_TO_THIS_REPOSITORY%` with the full path to this repository.

> [!NOTE]
> The commands below will forward the scripts output to a file in this repository, named `sunvdm.log` - this is optional and can be removed if you don't care for logs / can be directed somewhere else.

### Option 1 - UI

In the Sunshine UI navigate to Configuration, and go to the General Tab.

At the bottom, in the `Command Preparations` section, you will press the `+Add` button to add a new command.

In the first text box `config.do_cmd`, use:

```batch
cmd /C ""%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PATH_TO_THIS_REPOSITORY%\setup_sunvdm.ps1" *> "%PATH_TO_THIS_REPOSITORY%\sunvdm.log""
```

In the second text box `config.undo_cmd`, use:

```batch
cmd /C ""%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PATH_TO_THIS_REPOSITORY%\teardown_sunvdm.ps1" *>> "%PATH_TO_THIS_REPOSITORY%\sunvdm.log""
```

> [!WARNING]
> Make sure to replace `%PATH_TO_THIS_REPOSITORY%` with the correct path to the folder containing the scripts.

> [!NOTE]
> Select the checkbox for `config.elevated` under the `config.run_as` column (we need to run as elevated in order to enable/disable the display device and apply topology changes).

### Option 2 - Config File

You can set the following in your `sunshine.conf` config file:

```batch
global_prep_cmd = [{"do":"cmd /C \"\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%PATH_TO_THIS_REPOSITORY%\\setup_sunvdm.ps1\" *> \"%PATH_TO_THIS_REPOSITORY%\\sunvdm.log\"\"","undo":"cmd /C \"\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%PATH_TO_THIS_REPOSITORY%\\teardown_sunvdm.ps1\" *>> \"%PATH_TO_THIS_REPOSITORY%\\sunvdm.log\"\"","elevated":"true"}]

```

> [!NOTE]
> If you already have something in the `global_prep_cmd` that you setup, you should be informed enough to know where/how to add this to the list.
