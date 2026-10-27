# Sample document
<!-- gfm2pdf
common:
  metadata:
    subtitle: "Sample subtitle"
    author: "Sample Author"
-->

## Introduction

Hello from the sample, see the [details](#details).

> [!NOTE]
> Use option `--transfer=direct` to execute `ascp` locally.

![Logo](image.svg)

## Details

| Field | Type | Description |
| --- | --- | --- |
| `download_partial_suffix` | `String` | File suffix appended to the target filename while a download is in progress.<br/>Default: `.partial`. |
| `retry_max` | `Integer` | Maximum number of retry attempts. |

```shell
ascli config preset overview
alias asclish="podman run --rm --tty --interactive --user root --env ASCLI_HOME=/home/cliuser/.aspera/ascli --volume $HOME/.aspera/ascli:/home/cliuser/.aspera/ascli --entrypoint bash docker.io/martinlaurent/ascli:latest"
```
