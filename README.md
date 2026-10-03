<div align="center">

# mwmbar

A workspace bar with app icons, because somehow no one does it

<img width="560" height="72" alt="mwmbar_demo" src="https://github.com/user-attachments/assets/a32b09de-391b-477d-89a5-02d8cfa994c2" />

</div>

> [!NOTE]
> Only [Aerospace](https://github.com/nikitabobko/AeroSpace) is supported for now.

## Installation

Homebrew (macOS):

```sh
brew tap skardyy/mwmbar https://github.com/Skardyy/mwmbar.git
brew install mwmbar
```

nix-darwin:

```nix
{ ... }: {
  homebrew.taps = [
    {
      name = "skardyy/mwmbar";
      clone_target = "https://github.com/Skardyy/mwmbar.git";
      trusted = true;
    }
  ];
  homebrew.brews = [ "mwmbar" ];

  launchd.user.agents.mwmbar = {
    serviceConfig = {
      Label = "com.skardyy.mwmbar";
      ProgramArguments = [ "/opt/homebrew/bin/mwmbar" ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Interactive";
      StandardErrorPath = "/tmp/mwmbar.err.log";
      StandardOutPath = "/tmp/mwmbar.out.log";
    };
  };
}
```
