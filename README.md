# emptyDir Cache Lab

An interactive simulator and a cluster test script that explain what really happens when a Kubernetes pod uses an `emptyDir` volume as a cache, and how it affects the other pods on the same node.

It answers questions like:

- Does a memory limit protect me from a disk-backed cache filling up? *(No.)*
- What is the difference between a pod being **Evicted** and being **OOMKilled**?
- Why does a pod with `medium: Memory` end up in **CrashLoopBackOff**?
- My pods each have `sizeLimit: 3Gi`. Why did the node still hit **DiskPressure**?

<!-- Add a screenshot: save one as docs/screenshot.png and uncomment the next line -->
<!-- ![emptyDir Cache Lab](docs/screenshot.png) -->

**Live demo:** `https://<your-github-user>.github.io/emptydir-cache-lab/` *(after enabling GitHub Pages, see below)*

---

## Contents

- [What's in this repository](#whats-in-this-repository)
- [Quick start](#quick-start)
- [Key concepts](#key-concepts)
- [The scenarios](#the-scenarios)
- [Impact on other pods](#impact-on-other-pods)
- [Recommended configuration](#recommended-configuration)
- [Risks that limits don't cover](#risks-that-limits-dont-cover)
- [Test script reference](#test-script-reference)
- [How the simulator works](#how-the-simulator-works)
- [Publish with GitHub Pages](#publish-with-github-pages)
- [Contributing](#contributing)
- [License and disclaimer](#license-and-disclaimer)

---

## What's in this repository

```
emptydir-cache-lab/
├── index.html                    # the interactive lab (single file, no build)
├── scripts/
│   └── emptydir-scenarios.sh     # runs the scenarios on a real cluster and records the outcome
├── docs/                         # optional: screenshots, write-ups
├── LICENSE
└── README.md
```

| Component | Built with | Needs |
|---|---|---|
| `index.html` | Plain HTML, CSS and JavaScript. No frameworks or libraries. | Any modern browser. Works offline (falls back to system fonts). |
| `emptydir-scenarios.sh` | Bash | `kubectl`, `jq`, a test cluster, RBAC on `nodes/proxy` for kubelet stats |

---

## Quick start

### Run the lab

```bash
git clone https://github.com/<your-github-user>/emptydir-cache-lab.git
cd emptydir-cache-lab
open index.html          # macOS
xdg-open index.html      # Linux
start index.html         # Windows
```

Or just double-click `index.html`. No server, no install.

In the lab:

1. Pick a scenario button (`#1` to `#11`, or **★ Fix** for the recommended config).
2. Click **Replay cache filling** to watch the cache grow until a limit trips.
3. Change any setting (medium, `sizeLimit`, memory limit, ephemeral-storage, app memory, pods per node, node disk/RAM) and see the outcome update.
4. Use the tabs below for key concepts, the full scenario table, recommendations and a tmpfs sizing calculator.

Tip: add `#s5` (or `#s1`…`#s11`, `#sR`) to the URL to open a specific scenario directly.

### Run the scenarios on a cluster

> **Use a test cluster or a dedicated test node.** Scenarios 4, 5 and 9 can fill a node's disk or RAM and are skipped unless you set `ALLOW_NODE_IMPACT=1`.

```bash
cd scripts
chmod +x emptydir-scenarios.sh

./emptydir-scenarios.sh list                       # list scenarios
./emptydir-scenarios.sh show 6                     # print a manifest without applying it

NODE=worker-3 ./emptydir-scenarios.sh run 1 2 3 6 7 8
NODE=worker-3 ALLOW_NODE_IMPACT=1 ./emptydir-scenarios.sh run 4 5 9

# small test node: scale everything down
SIZE_SMALL=1Gi SIZE_LARGE=2Gi MEM_LIMIT=2Gi WRITE_GB=3 NODE=worker-3 ./emptydir-scenarios.sh run all

./emptydir-scenarios.sh cleanup                    # delete the test namespace
```

---

## Key concepts

### Evicted vs OOMKilled

| | Evicted | OOMKilled |
|---|---|---|
| **Who acts** | kubelet (checks about every 10s) | Linux kernel (immediately, at the cgroup limit) |
| **Trigger** | emptyDir over `sizeLimit`, ephemeral-storage over limit, or node DiskPressure / MemoryPressure | Memory use (including tmpfs files) reaches the container's memory limit, or the node runs out of memory |
| **What stops** | The whole pod. A Deployment/StatefulSet creates a replacement. | A process in the container. The container restarts in the same pod. |
| **emptyDir data** | Deleted. The new pod starts with an empty cache. | Kept. The restarted container sees the old cache. |
| **How it shows** | `status.reason: Evicted`, message like `Usage of EmptyDir volume "cache" exceeds the limit "3Gi".` | `lastState.terminated.reason: OOMKilled`, exit code 137 |

### Five facts that explain every scenario

1. **`sizeLimit` on a disk emptyDir is not a hard quota.** The kubelet measures the volume periodically and evicts the pod once it's over. A fast writer can overshoot first, and the app never sees "disk full".
2. **The scheduler ignores `sizeLimit`.** Only `ephemeral-storage` *requests* reserve disk on a node. Many pods with 3Gi limits can together need more disk than the node has.
3. **Disk writes use page cache.** It's charged to the container's memory cgroup but is reclaimable, so it shows as high memory usage without causing OOM kills.
4. **A tmpfs emptyDir (`medium: Memory`) is real RAM.**
   - Files count as container memory and can't be reclaimed.
   - `sizeLimit` becomes the tmpfs mount size: writes past it fail with `ENOSPC`, no eviction.
   - Without `sizeLimit`, the tmpfs is sized to the pod's memory limit, or node allocatable memory if there's no limit (Kubernetes 1.22+).
   - tmpfs data survives container restarts and does **not** count toward ephemeral-storage.
5. **Who goes first under node pressure:**
   - Kernel OOM killer uses `oom_score_adj`: BestEffort 1000 (first), Burstable 2–999, Guaranteed −997 (last).
   - kubelet eviction ranks by usage above request, then priority class, then amount above request.
   - Ephemeral-storage settings don't change the QoS class.

---

## The scenarios

| # | Setup | Cache size enforced by | Memory enforced by | What happens when the cache fills | Risk to other pods |
|---|---|---|---|---|---|
| 1 | Disk, `sizeLimit: 3Gi`, no limits | kubelet polling (3Gi) | Nothing | Pod **Evicted** at 3Gi, cache lost, replacement starts cold. Memory unbounded. | Medium |
| 2 | Disk, `sizeLimit: 3Gi`, memory limit 10Gi | kubelet polling (3Gi) | cgroup (10Gi) | Evicted at 3Gi; OOMKilled only if app memory reaches 10Gi | Low |
| 3 | Disk, `sizeLimit: 10Gi`, memory limit 10Gi | kubelet polling (10Gi) | cgroup (10Gi) | Evicted at 10Gi. Several such pods can fill the node disk (scheduler doesn't reserve it). | Medium |
| 4 | Disk, no `sizeLimit`, no limits | Nothing | Nothing | Node **DiskPressure**: neighbors evicted, taint blocks new pods, images removed; at 100% full the node can go **NotReady** | **High** |
| 5 | tmpfs, no `sizeLimit`, no limits | Nothing (tmpfs = node allocatable) | Nothing | Node **MemoryPressure**; kernel OOM kills across the node. Killing processes doesn't free tmpfs, so kills continue until the pod is evicted. | **Critical** |
| 6 | tmpfs, no `sizeLimit`, memory limit 10Gi | tmpfs = memory limit | cgroup (10Gi, shared with cache) | **OOMKilled**, then **CrashLoopBackOff**: tmpfs files survive the restart and still count | Low (High for the app) |
| 7 | tmpfs, `sizeLimit: 3Gi`, memory limit 10Gi | tmpfs size (kernel, hard) | cgroup (10Gi) | Writes fail with `ENOSPC` at 3Gi, pod keeps running. *Recommended tmpfs pattern.* | Low |
| 8 | Disk, ephemeral-storage request 3Gi / limit 5Gi | kubelet (ephemeral-storage limit) | Nothing | Evicted at 5Gi total (cache + logs + writable layer). Disk reserved by scheduler. *Recommended disk pattern.* | Low for disk |
| 9 | No emptyDir, cache in the container filesystem | Nothing | Nothing | Same as #4, and harder to spot | **High** |
| 10 | tmpfs, `sizeLimit` = memory limit (10Gi/10Gi) | tmpfs size (never reached) | cgroup (10Gi, shared) | Zero headroom for the app: OOMKilled before the size cap, then CrashLoopBackOff | Low (High for the app) |
| 11 | 15 pods × disk `sizeLimit: 3Gi`, no limits, 40Gi free | kubelet polling (per pod) | Nothing | Each pod is limited, the total isn't: node DiskPressure at ~2.4Gi per pod | **High** |

Scenarios 1–10 can be run on a cluster with the test script. Scenario 11 and the recommended fix are available in the lab.

---

## Impact on other pods

| Scope | Scenarios | Why |
|---|---|---|
| **Contained in the pod** | 2, 6, 7, 8, 10 | Memory capped by the cgroup; disk capped per pod (and reserved, in #8) |
| **Can reach neighbors** | 1, 3, 11 | No memory cap (#1), or disk not reserved by the scheduler so the total can overcommit (#3, #11) |
| **Whole node** | 4, 5, 9 | Nothing limits the cache; node pressure evicts or OOM-kills healthy pods and can take the node NotReady |

---

## Recommended configuration

For many pods with a disk-backed cache at `sizeLimit: 3Gi` and no memory limits:

```yaml
spec:
  containers:
  - name: app
    resources:
      requests:
        cpu: "500m"                  # from observed usage
        memory: "2Gi"                # observed p95
        ephemeral-storage: "3.5Gi"   # 3Gi cache + logs + writable layer
      limits:
        memory: "3Gi"                # p95 + ~30-50% headroom
        ephemeral-storage: "4Gi"
    volumeMounts:
    - {name: cache, mountPath: /cache}
  volumes:
  - name: cache
    emptyDir:
      sizeLimit: 3Gi
```

**Most important change, in the application:** set the app's own maximum cache size *below* `sizeLimit` (e.g. 2.4–2.5Gi for 3Gi). The app then removes old entries itself and the kubelet never needs to evict the pod.

**Rollout:**

1. **Measure** real memory and cache usage per pod (`kubectl top pod`, kubelet stats).
2. **Check capacity:** total ephemeral-storage requests must fit each node's allocatable storage, with margin above the 10% eviction threshold.
3. **Enforce defaults** with a namespace `LimitRange`; optionally a `ResourceQuota` on `requests.ephemeral-storage` and `limits.memory`.
4. **Test** on one node with `scripts/emptydir-scenarios.sh`, then roll out gradually.

**tmpfs sizing rule:** memory limit ≥ cache `sizeLimit` + app peak memory + 20–30% margin.
Example: 3Gi cache + 4Gi app peak → about **9–10Gi**. The lab includes a calculator.

---

## Risks that limits don't cover

- **Disk I/O:** no per-pod IOPS/bandwidth limit by default. A heavy cache writer slows neighbors' I/O and logging (and etcd on control-plane nodes).
- **Inodes:** `sizeLimit` counts bytes, not files. Many small files can exhaust inodes and trigger DiskPressure (`nodefs.inodesFree<5%`).
- **Priority classes:** within the same QoS class, higher-priority pods survive longer, so neighbors may be evicted first.
- **Mass refill:** pods evicted together refill their caches at the same time and can saturate disk I/O.
- **Namespace defaults:** a `LimitRange` can silently apply limits the app team doesn't expect.
- **Alternative:** a PVC or generic ephemeral volume gives a filesystem-enforced size limit and keeps cache I/O off the node root disk.

---

## Test script reference

`scripts/emptydir-scenarios.sh` creates one pod per scenario with a busybox writer that fills the cache in chunks, then samples pod status, kubelet stats and node conditions until something happens.

### Commands

| Command | Description |
|---|---|
| `list` | List scenarios and mark the ones that can impact the node |
| `show <id>` | Print the pod manifest for a scenario |
| `run <id...>` / `run all` | Run scenarios one at a time and write a summary |
| `cleanup` | Delete the test namespace |

### Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `NS` | `emptydir-test` | Namespace (created if missing) |
| `NODE` | *(unset)* | Pin pods to one node. **Strongly recommended.** |
| `SIZE_SMALL` / `SIZE_LARGE` | `3Gi` / `10Gi` | emptyDir `sizeLimit` values |
| `MEM_LIMIT` | `10Gi` | Memory limit in "with limits" scenarios |
| `EPH_REQ` / `EPH_LIM` | `3Gi` / `5Gi` | Ephemeral-storage request/limit (scenario 8) |
| `WRITE_GB` | `12` | How much the writer tries to write |
| `CHUNK_MB` | `256` | Size of each written file |
| `WRITE_DELAY` | `0` | Seconds between chunks (simulate a slow writer) |
| `WATCH_SECS` | `300` | Max observation time per scenario |
| `POLL` | `5` | Seconds between samples |
| `IMAGE` | `busybox:1.36` | Writer image |
| `ALLOW_NODE_IMPACT` | `0` | Set to `1` to run scenarios 4, 5, 9 |
| `OUT_DIR` | `./emptydir-results-<timestamp>` | Where evidence is saved |

### Outcomes

| Outcome | Meaning |
|---|---|
| `EVICTED` | kubelet evicted the pod (sizeLimit, ephemeral-storage or node pressure) |
| `OOMKilled_LOOP(restarts=N)` | Container OOM-killed repeatedly (CrashLoopBackOff) |
| `ENOSPC` | Writes failed with "No space left on device" (tmpfs full) |
| `COMPLETED_NO_ACTION` | Writer finished and nothing stopped it |
| `UNSCHEDULABLE` | Pod not scheduled within 60s |
| `SKIPPED` | Dangerous scenario skipped (no `ALLOW_NODE_IMPACT=1`) |
| `TIMEOUT` | Nothing happened within `WATCH_SECS` |

### Evidence collected per scenario

`pod.yaml`, `pod-final.yaml`, `describe.txt`, `logs.txt`, `logs-previous.txt`, `events.txt`, `node-events.txt` and `samples.tsv` (time series of phase, restarts, cache size, working set, ephemeral usage, node free disk/memory, DiskPressure, MemoryPressure). A `summary.md` table is written at the end.

---

## How the simulator works

For each setting combination, the lab works out the cache size at which each limit would trip, then takes the first one that stops the cache from growing:

| Event | Trips at (cache per pod) | Stops growth? |
|---|---|---|
| App reaches its own cache cap | `cap` | Yes, stable |
| tmpfs full (`ENOSPC`) | tmpfs size = `min(sizeLimit, memory limit or node allocatable)` | Yes, pod keeps running |
| Evicted by `sizeLimit` (disk) | `sizeLimit` | Yes |
| Evicted by ephemeral-storage | ephemeral-storage limit | Yes |
| OOMKilled (tmpfs) | `memory limit − app memory` | Yes, CrashLoopBackOff |
| Node DiskPressure | `0.9 × free disk ÷ pods` | Yes, node-wide |
| Node MemoryPressure (tmpfs) | `node allocatable ÷ pods − app memory` | Yes, node-wide |

Scheduling is modeled from requests: `ephemeral-storage` requests and memory limits (request = limit) decide how many pods fit; the rest stay Pending.

**Assumptions:**

- Default kubelet hard-eviction thresholds: `nodefs.available<10%`, `memory.available<100Mi`.
- Kubernetes 1.22+ tmpfs sizing (`SizeMemoryBackedVolumes`).
- All pods on the node are identical.
- Container logs and the kubelet's polling overshoot aren't counted.

Real clusters can differ. Confirm with the test script.

To change the scenarios, edit the `PRESETS` list in `index.html`; the logic lives in `evaluate()`.

---

## Publish with GitHub Pages

1. Push this repository to GitHub.
2. Go to **Settings → Pages**.
3. Under **Build and deployment**, choose **Deploy from a branch**, select `main` and `/ (root)`, then **Save**.
4. After a minute the lab is live at `https://<your-github-user>.github.io/emptydir-cache-lab/`.

---

## Contributing

Issues and pull requests are welcome, especially:

- results from running the test script on different Kubernetes versions, runtimes or cgroup versions
- new scenarios (PVC caches, generic ephemeral volumes, multi-container pods)
- corrections where real behavior differs from the model

---

## License and disclaimer

Released under the [MIT License](LICENSE).

This is an educational tool. The simulator is a simplified model and the test script deliberately stresses nodes. Run it only on clusters you own and can afford to disrupt. It is not affiliated with or endorsed by any company.
