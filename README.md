# AniWatch API Downloader (`aniwatch-dl.sh`)

<div align="center">

[![Shell](https://img.shields.io/badge/Shell-Bash-8caaee?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-MIT-e5c890?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://opensource.org/licenses/MIT)
[![Stars](https://img.shields.io/github/stars/ruxartic/aniwatch-dl?style=flat-square&logo=github&color=babbf1&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ruxartic/aniwatch-dl)
[![Forks](https://img.shields.io/github/forks/ruxartic/aniwatch-dl?style=flat-square&logo=github&color=a6d189&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ruxartic/aniwatch-dl)
[![API](https://img.shields.io/badge/API-AniWatch%20API-ca9ee6?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ghoshRitesh12/aniwatch-api)

</div>

`aniwatch-dl.sh` is a powerful command-line tool written in Bash to download anime series and episodes from an [AniWatch-compatible API](https://github.com/ghoshRitesh12/aniwatch-api) instance. It offers features like anime searching, flexible episode selection, resolution preference, server choice, and subtitle management.

> [!NOTE]
> This script is designed to work with a running instance of an AniWatch-compatible API. You must configure the script to point to a valid API endpoint before use. See the [Configuration](#️-configuration) section for details.

## ✨ Features

*   **Anime Discovery:**
    *   Search for anime by name.
    *   Select from search results using an interactive `fzf` menu with detailed previews.
    *   Alternatively, specify anime directly by its API ID.
*   **Flexible Episode Selection:**
    *   Download single episodes, multiple specific episodes, ranges, or all available.
    *   Exclude specific episodes or ranges.
    *   Select the latest 'N', first 'N', from 'N' onwards, or up to 'N' episodes.
    *   Combine selection criteria (e.g., `"1-10,!5,L2"`).
    *   Interactive prompt for episode selection if not provided via command-line.
*   **Download Customization:**
    *   Choose preferred audio type (subbed or dubbed).
    *   Specify preferred resolution via keywords (e.g., "1080", "720") to select the M3U8 variant stream.
    *   Specify preferred server via keywords (e.g., "megacloud", "vidstreaming") to filter server choices.
    *   If no resolution preference is given, selects the highest bandwidth M3U8 variant stream by default.
*   **Subtitle Management:**
    *   Default behavior: Downloads an "English" subtitle track if available.
    *   `-L <langs>`: Option to specify preferred subtitle languages (e.g., "eng,spa,jpn").
    *   `-L all`: Option to download all available subtitles.
    *   `-L none`: Option to disable subtitle downloads.
*   **Efficient Downloading:**
    *   Parallel segment downloads using GNU Parallel for faster HLS stream processing.
    *   Configurable number of download threads (`-t <num>`).
    *   Optional timeout for individual segment downloads (`-T <secs>`).
*   **User Experience:**
    *   Colorized and informative terminal output.
    *   Debug mode (`-d`) for verbose logging.
    *   Option to list stream links without downloading (`-l`).
    *   Organized video downloads into `~/Videos/AniWatchAnime/<Anime Title>/` by default (configurable via `ANIWATCH_DL_VIDEO_DIR`).

## Prerequisites

Before you can use `aniwatch-dl.sh`, you need the following command-line tools installed on your system:

*   **`bash`**: Version 4.0 or higher recommended.
*   **`curl`**: For making HTTP requests to the API and downloading files.
*   **`jq`**: For parsing JSON responses from the API.
*   **`fzf`**: For interactive selection menus.
*   **`ffmpeg`**: For concatenating downloaded HLS video segments and embedding metadata.
*   **`GNU Parallel`**: For parallel downloading of HLS segments.
*   **`mktemp`**: For creating temporary directories (usually part of coreutils).

<br/>

> [!TIP]
> You can usually install these dependencies using your system's package manager.

<details>
<summary>Installing Dependencies</summary>

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y bash curl jq fzf ffmpeg parallel
```

### Fedora

```bash
sudo dnf install -y bash curl jq fzf ffmpeg parallel
```

### Arch Linux

```bash
sudo pacman -Syu bash curl jq fzf ffmpeg parallel
```

### macOS (using Homebrew)

```bash
brew install bash curl jq fzf ffmpeg parallel coreutils
```

> On Windows, you can use WSL (Windows Subsystem for Linux) to run this script. Make sure to install the required dependencies in your WSL environment.

</details>

## 🚀 Installation

1.  **Download the script:**
    Save the script content as `aniwatch-dl.sh` in your desired location.

    ```bash
    # using curl:
    curl -o aniwatch-dl.sh https://raw.githubusercontent.com/ruxartic/aniwatch-dl/main/aniwatch-dl.sh

    # using git (clone the repo):
    git clone https://github.com/ruxartic/aniwatch-dl.git
    cd aniwatch-dl
    ```

2.  **Make the script executable:**

    ```bash
    chmod +x aniwatch-dl.sh
    ```

3.  **(Optional) Place it in your PATH:**
    For easier access, move or symlink `aniwatch-dl.sh` to a directory in your `PATH`, like `~/.local/bin/`:

    ```bash
    # Example: create a symlink named 'animew'
    ln -s /path/to/your/aniwatch-dl.sh ~/.local/bin/animew
    ```

## ⚙️ Configuration

The script **requires** the `ANIWATCH_API_URL` environment variable to be set to the base URL of your API instance.

1.  **Set the Environment Variable `ANIWATCH_API_URL`**: This is the **only** way to configure the API endpoint.

    ```bash
    # Example for your current shell session:
    export ANIWATCH_API_URL="https://your-aniwatch-api.vercel.app"
    # Then run the script:
    ./aniwatch-dl.sh -a "Frieren"
    ```

    To make this configuration permanent, add the `export` line to your shell's startup file (e.g., `~/.bashrc`, `~/.zshrc`, `~/.profile`).

> [!IMPORTANT]
> The script will fail with an error if the `ANIWATCH_API_URL` environment variable is not set or is empty.

**Other Environment Variables:**

*   **`ANIWATCH_DL_VIDEO_DIR`**: Sets the root directory for downloaded anime.
    *   Default: `"$HOME/Videos/AniWatchAnime"`
    *   Example: `export ANIWATCH_DL_VIDEO_DIR="$HOME/MyAnime"`
*   **`ANIWATCH_DL_TMP_DIR`**: Sets a custom parent directory for temporary files.
    *   Default: `"$ANIWATCH_DL_VIDEO_DIR/.tmp"`
    *   Example: `export ANIWATCH_DL_TMP_DIR="/mnt/fast-ssd/tmp"`

## 📖 Usage

```
./aniwatch-dl.sh [OPTIONS]
```

**Common Options:**

```
Mandatory (one of these):
  -a <anime_name>        Anime name to search for (ignored if -i is used).
  -i <anime_id>          Specify anime ID directly.

Episode Selection:
  -e <selection>         Episode selection string. Examples:
                         - Single: "1"
                         - Multiple: "1,3,5"
                         - Range: "1-5"
                         - All: "*"
                         - Exclude: "*,!1,!10-12" (all except 1 and 10-12)
                         - Latest N: "L3" (latest 3 available)
                         - First N: "F5" (first 5 available)
                         - From N: "10-" (episode 10 to last available)
                         - Up to N: "-5" (episode 1 to 5)
                         - Combined: "1-10,!5,L2" (1-10 except 5, plus latest 2)
                         If omitted, the script will prompt for selection.

Download Preferences:
  -r <keyword>           Optional, resolution keyword (e.g., "1080", "720").
  -S <server_keyword>    Optional, keyword for preferred server (e.g., "megacloud").
  -o <type>              Optional, audio type: "sub" or "dub". Default: "sub".
  -L <langs>             Optional, subtitle languages (comma-separated codes like "eng,spa",
                         or "all", "none", "default"). Default: "default".

Performance & Output:
  -t <num_threads>       Optional, threads for segment downloads. Default: 4.
  -T <timeout_secs>      Optional, timeout for segment download jobs.
  -l                     Optional, list stream links without downloading.
  -d                     Enable debug mode for verbose output.
  -h | --help            Display the help message.
```

### Examples

*   **Search for "Frieren" and download episode 1 (subbed, default subtitle behavior):**

    ```bash
    ./aniwatch-dl.sh -a "Frieren" -e 1
    ```

*   **Download episodes 5 to 10 and the latest 2 of an anime with ID `sousou-no-frieren-18456`, dubbed:**

    ```bash
    ./aniwatch-dl.sh -i "sousou-no-frieren-18456" -e "5-10,L2" -o dub
    ```

*   **Download episodes 1-5 using 8 threads for faster downloading:**
    ```bash
    ./aniwatch-dl.sh -a "Solo Leveling" -e "1-5" -t 8
    ```

*   **Download all episodes of an anime except ep 3, prefer 720p, and get Spanish subtitles:**

    ```bash
    ./aniwatch-dl.sh -a "Some Anime" -e "*,!3" -r 720 -L spa
    ```

*   **List stream links for episode 1 of "Another Anime" without downloading:**

    ```bash
    ./aniwatch-dl.sh -a "Another Anime" -e 1 -l
    ```

## 🛠️ How It Works

1.  **Initialization**: Reads `ANIWATCH_API_URL` and other environment variables, then checks for dependencies.
2.  **Anime Identification**:
    *   With `-a`, searches via `/api/v2/hianime/search` and uses `fzf` for interactive selection.
    *   With `-i`, fetches info directly from `/api/v2/hianime/anime/{anime_id}`.
3.  **Episode List Retrieval**: Fetches all episodes via `/api/v2/hianime/anime/{anime_id}/episodes`.
4.  **Episode Selection**: Parses the `-e <selection>` string or prompts the user interactively.
5.  **Stream Details Acquisition (for each episode):**
    *   Gets a server list from `/api/v2/hianime/episode/servers`.
    *   Filters servers by user preferences (`-S`, `-o`).
    *   Gets the final stream info (M3U8 URL, subtitles) from `/api/v2/hianime/episode/sources`.
6.  **M3U8 Handling (HLS):**
    *   Downloads the master M3U8 playlist.
    *   Parses it to find available quality variants.
    *   Selects the best variant based on `-r <keyword>` or the highest bandwidth.
    *   Downloads the corresponding media M3U8 which contains the segment URLs.
7.  **Downloading**:
    *   HLS segments are downloaded in parallel using GNU Parallel.
    *   Subtitles are downloaded based on the `-L <langs>` preference.
8.  **Assembly (HLS)**: `ffmpeg` safely concatenates all downloaded segments into a single `.mp4` file and embeds the episode title and number as metadata.
9.  **File Organization**: Saves files to `ANIWATCH_DL_VIDEO_DIR/ANIME_TITLE/Episode_NUM_TITLE.mp4`.
10. **Cleanup**: Atomically removes only the temporary directories created during its own run, ensuring safety during concurrent script executions.

<br/>

## 📜 Disclaimer

> [!WARNING]
> Downloading copyrighted material may be illegal in your country. This script is provided for educational purposes and for use with legitimately accessed API instances. Please respect copyright laws and the terms of service of any API provider. Use this script at your own risk.

## 🤝 Contributing

Contributions are welcome! If you have suggestions, bug fixes, or feature requests, please open an issue or submit a pull request on the project repository.

## 📜 License

This project is licensed under the [MIT License](LICENSE).
