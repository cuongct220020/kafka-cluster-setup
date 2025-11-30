## Cách Partition hoạt động (How Partition work?)

### 1. Partition là gì và tại sao quan trọng? 

**Partition = 1 log file append-only**

Trong Kafka, **topic chỉ là khái niệm logic**, còn **partition mới là đơn vị vật lý chứa dữ liệu**. 
* Mỗi partition là 1 file log ghi tuần tự (append-only).
* Kakfa không scale theo topic, mà **scale theo partition**.
* Partition cũng là đơn vị song song (concurrency unit) cho cả producer và consumer. 


### 2. Vì sao partition quyết định khả năng scale?

**(A) Producer scale theo partition**

* Producer có thể ghi song song vào nhiều partition. 
* Nếu topic có 10 partition thì Kafka có thể xử lý nhiều request ghi cùng lúc hơn topic có 1 partition. 

**(B) Consumer group scale theo partition**

* Một consumer group = nhiều consumer instance (client) cùng đọc một topic.
* Nhưng **mỗi partition tại một thời điểm chỉ được đọc bởi đúng 1 consumer trong group.**

-> Vì vậy, số consumer tối đa của 1 group = số partition. 

### 3. Quy tắc quan trọng: Consumers không chia sẻ partition

Trong cùng một consumer group: 

> **1 partiton chỉ được đọc bởi 1 consumer tại một thời điểm. Không bao giờ có 2 consumer cùng đọc 1 partition tại một thời điểm.**

Kafka đảm bảo điều này để:
* Giữ thứ tự trong partition (Message ordering). 
* Tránh double-consume (hai consumer xử lý trùng dữ liệu).

### 4. Những trường hợp phổ biến

**Case 1: Consumer <= Partitions (best practices)**

Ví dụ: 
* Topic có 6 partions
* Group có 3 consumers

$\rightarrow$ Kafka gán mỗi consumer với 2 partitons. 

| Consumer | Partitions |
|----------|------------|
| C1       | P0, P1     |
| C2       | P2, P3     |
| C3       | P4, P5     |

$\rightarrow$ Tất cả consumer đều có việc, hệ thống scale tốt. 

**Note:** Nếu số lượng Partition quá nhiều so với số lượng Consumer thì khối lượng tính toán (workload)
mà một consumer cần xử lý sẽ tăng lên, điều này gây ra chi phí overhead cho consumer. 

**Case 2: Consumers > Partitions**

Ví dụ: 
* Topic có 2 partions
* Group có 4 consumer

$\rightarrow$ Kafka chỉ có 2 partition để phân: 

| Consumer | Partitions |
|----------|------------|
| C1       | P0         |
| C2       | P1         |
| C3       | idle       |
| C4       | idle       |

$\rightarrow$ **Consumers dư sẽ bị "starvation" (đói việc)**. Kafka sẽ không chia 1 partition cho 2 consumer. 

### 5. Rebalance khi có consumer vào/ra

**Khi 1 consumer chết:** Kafka sẽ 
1. Phát hiện consumer mất hearbet. 
2. Trigger rebalance. 
3. Chia lại parttions cho các consumer còn sống

**Khi thêm consumer**
1. Kakfa sẽ rebalance để phân lại partitions
2. Nhưng nếu số consumer > partition $\rightarrow$ consumer mới vẫn rảnh rỗi (idle)

### 6. Ordering: Thứ tự chỉ đảm bảo trong 1 partition

Kafka chỉ đảm bảo: **thứ tự message trong 1 partition không bao giờ đổi.**

Còn giữa các partition khác nhau: 
* message có thể đến trước/sau tuỳ lúc producer gửi
Nếu yêu cầu: 
* "mọi message của cùng một key phải 1 partition"

$\rightarrow$ Dùng **partitioning by key**, Kafka sẽ hash key $\rightarrow$ chọn partition. 

### 7. Tóm lại

**Partition quyết định:**
* Khả năng song song của producer và consumer. 
* Số consumer tối đa trong cùng 1 group. 
* Tính ordering của data. 
* Throughput của hệ thống. 

---

## Thiết kế số partitions, cách producer chọn partition, consumer group

### 1. Thiết kế số partitions hợp lý - tư duy, con số, trade-offs. 

#### Bản chất
**Partition = unit of parallelism + unit of replication + unit of metadta.**  
Mỗi partition có leader (ghi/đọc) và 0...N follower replica; mỗi partition tạo ra các trạng thái, 
stream replication và entry trong metadata của controller/broker. Vì vậy, tăng **partition** đồng nghĩa
tăng số đơn vị nền tảng mà broker phải quản lý (threads, timers, file handlers, fetch requests, ISR management). 

#### Nguyên tắc thiết kế
1. **Số partition ~ số consumer instances (đang chạy) bạn muốn scale tới**, cộng margin. 
Nếu muốn tối đa 20 consumers đồng thời trong một consumer group, cần >= 20 partitions 
(để cân bằng, chọn số có nhiều ước - 12, 24, 36...).
2. **Không quá ít, không quá nhiều:** quá ít thì không thể scale; quá nhiều thì overhead metadata, CPU, ổ cứng, leader, election kéo dài. 
Thước đo thực tế: **hạn mức an toàn thường thấy là vai trăm $\rightarrow$ 1-4k partitions/broker tuỳ workload và phần cứng**; vượt con số này cần test kĩ.
(không có "một con số cho tất cả").
3. **Ưu tiên tăng partitions cho topic hot** (throughput cao) thay vì tạo nhiều topics nhỏ. Thường 1 topic nhiều partition ít overhead hơn nhiều topic nhỏ cùng 
tổng partition vì metadata/topic-level state tăng theo số topic. Đây là chính xác điều Instaclustr đã đo. 

#### Con số tham khảo để bắt đầu (rule-of-thumb)
* Small cluster (mấy broker, dev): < 100 partitions/broker. 
* Prod medium: 100 - 1000 partitions/broker. 
* Very large & tuned: 1k–4k partitions/broker (cần tuning OS, JVM, thread pools, file handles)


### 2. Producer chọn partition - chính xác cơ chế và hệ quả thực tế

#### Cơ chế tiêu chuẩn
* Nếu producer gửi có key: Kafka client/hash partitioner sử dụng dụng `hash(key) % numPartitions` để chọn partition (đảm bảo **ordering cho cùng ke**y).
* Nếu **không có key:** Mặc định **round-robin** (với các client hiện đại có affinity để tận dụng batching), phân phối đều qua partitions để tận dụng batching.  

#### **Hệ quả quan trọng**
* **Thay đổi numPartitions** sẽ thay đổi mapping hash(key) $\rightarrow$ partition. Điều này không di chuyển dữ liệu cũ: các record cũ vẫn nằm ở partition cũ, 
record mới theo mapping mới $\rightarrow$ ordering theo key bị phá nếu bạn tăng partions (chỉ ordering trên partitions cũ giữ nguyên). 
Vì vậy cẩn trọng khi tăng partitions cho topic có yêu cầu ordering nghiêm ngặt. 
* Khi cần **đảm bảo ordering mạnh hơn** cho nhiều keys, cân nhắc: tăng partition + thiết kế key sao cho "hot keys" không chặn throughput (ví dụ: shared key nhỏ hơn, composite key).

#### Tuning producer để tối ưu throughput
* **Batching:** `linger.ms`, `batch.size`, `compression.type` - tăng batch giảm IOPS/CPU (nhưng tăng latency).
* **Idempotence & acks:** `enable.idempotence=true` + `acks=all` cho an toàn; sẽ ảnh hướng throughput/latency. 
* **Partition affinity:** custom partitioner nếu bạn muốn map theo vùng, tenant, hoặc hot-key logic.


### 3. Consumer group & Rebalance - chi tiết nội bộ, vấn đề vận hành và mititgations. 

#### Nguyên lý
* **Trong 1 consumer group: mỗi partition được assign cho đúng 1 consumer** (tại một thời điểm). 
Điều này giữ đảm bảo ordering trong partition. Khi số consumer ≤ số partition, mỗi consumer có 0..N partitions; 
nếu số consumer > partitions, consumer thừa sẽ idle.

#### Rebalance Lifecycle (kỹ thuật)
1. Consumer join/leave hoặc session timeout $\rightarrow$ group coordinator (1 broker) bắt đầu rebalance.
2. Coordinator thu metadata members $\rightarrow$  chọn assignment strategy (range, roundrobin, cooperative rebalancing nếu client hỗ trợ).
3. Coordinator gửi assignment cho từng consumer, consumer commit offsets, stop processing, re-subcribe, start processing mới. 
4. Nếu rebalance xảy ra thường xuyên, throughtput giảm, latency spike vì consumers dừng, khởi động lại. 

**Cooperative Rebalancing (KIP-429)** giảm downtime bằng incremental revoke/assign (nhiều client library hiện hỗ trợ), nhưng cần client & broker version tương thích.

**Vấn đề thực tế & mitigation**
* **Frequent rebalances:** Nguyên nhân thường là `session.timeout.ms` quá thấp, GC pauses trên consumer, hoặc nhiều consumer join/leave liên tục. 
Fix: điều chỉnh session timeouts, tăng `max.poll.interval.ms` cho workloads lâu xử lý. 
* **Large assignments:** Nếu 1 consumer nhận quá nhiều partitions, tăng pause khi xử lý startup/commit. Để giảm thời gian rebalance, giảm số partitions trên consumer
hoặc dùng cooperative strategy. 
* **Leader movement/ failover ảnh hướng:** Khi broker chết, controller phải elect leader cho từng partition led bởi broker đó. Nếu nhiều partition, thời gian recovery lớn. 
Điều này khiến rebalance và consumer downtime kéo dài. 


### 4. Partition ảnh hướng tới throughput, latency, cost - chi tiết sâu

#### Throughput

* Tăng partition $\rightarrow$ Tăng parallelism $\rightarrow$ tăng maximum aggregate throughput 
(producer/consumer có nhiều slot xử lý song song). Nhưng **điểm bù**: mỗi partitiion thêm overhead CPU / 
memory / disk metadata $\rightarrow$ đến 1 ngưỡng, throughput giảm do contention (threads, network, disk IO, context switching). 
Instaclustr đo thấy throughput tối ưu khi partitions nằm trong khoảng từ #cores tổng cụ thể $\rightarrow$ ~100 per cluster core; vượt quá sẽ giảm hiệu năng.


#### Latency
* Batching tradeoff: nhiều partition + small batches $\rightarrow$ tăng IOPS $\rightarrow$ low latency nhưng CPU/Network tăng;
mỗi latency thấp nhưng tiết kiệm tài nguyên, cần cân `linger.ms` và `batch.size`. 

* Replica lag & fetch settings có thể tạo latency cho commit (a.k.a. `acks=all` chờ HW), nếu follower chậm $\rightarrow$ leader block chờ HW advance $\rightarrow$ latency tăng.

#### Cost / Operational overhead


* **Storage:** Nhiều partition = nhiều segment files (inode), nhiều file handle - OS limits và disk metadata I/O tăng. 
* **Controller load:** metadata churn, leader election cost. 
* **Network & CPU:** replication traffic tăng theo RF và số partition (followers poll leaders). 
RF cao $\rightarrow$ traffic & CPU tăng tuyến tính theo số follower. 
Điều bạn quan sát (RF = 1 hầu như không tăng CPU, RF > 1 tăng mạnh) là hợp lý. 


### 5. Replication internals & config mà bạn cần biết (vì nó trực tiếp tác động CPU)

Một số config quan trọng (broker side) và ý nghĩa thực tế:
* `num.replica.fetchers`: Số fetcher thread per broker dùng để replicate từ leaders. Tăng giúp tăng parallelism replication nhưng tăng CPU/NET.
* `replica.fetch.max.bytes`: Max bytes follower request; nếu nhỏ $\rightarrow$ nhiều requests $\rightarrow$ overhead. Nếu quá lớn $\rightarrow$ memory pressure. 
* `replica.fetch.min.bytes` và `replica.fetch.wait.max.ms`: Follower sẽ trờ ít nhất min bytes hoặc tới wait.ms trước khi trả kết quả; tăng wait giúp giảm request rate (ít CPU) nhưng có thể tăng replication latency
**replica.fetch.min.bytes** nên nhỏ hơn `replica.lag.time.max.ms` để tránh ISR shrink behavior. 
* `replica.lag.time.max.ms`: Nếu follower không fetch trong thời gian này, có thể bị remove khỏi ISR (ảnh hưởng avaiability). 

**Thực tế:** RF=3 với 20k partitions $\rightarrow$ follower fetch requests cực nhiều; mỗi request gây context switches, IO, deserialization overhead. Vì vậy CPU tăng là hệ quả trực tiếp. 


### 6. Monitoring: metric nào bạn phải watch (và vì sao)
Theo các best practice, track ít nhất:
* **Broker/server metrics:** CPU, Disk IO Utilization, Network In/Out, File Descriptors open. 
* **Kafka JMX metrics:**
  * `UnderReplicatedPartitions` - Partitions không đủ replicas (đe doạ durability).
  * `OfflinePartitionsCount` - Partition offline. 
  * `ActiveControllercount` - Controller health. 
  * `RequestHandlerAvgIdlePercent` / `RequestHandlerAvgIdle` - quả tải request threads. 
  * `FollowerFetchRateAndLatency` / `ReplicaManager` metrics - theo dõi replicatin load. 
  * `LogFlushRateAndTimeMs`, `LogFlushLatency` - chỉ disk pressure. 


### 7. Practical tuning checklist
1. **Baseline:** đo CPU/IO/Network khi cluster idle; lấy baseline metrics. 
2. **Plan partition increment:** tăng partitions theo bước (ví dụ: +10% hoặc +100 partitions/step) và chờ **stabilize** 
(watch CPU, fetch rates, UnderReplicatedPartitions). AWS MSK/Instaclustr khuyên không reassign quá nhiều partitions cùng lúc (ví dụ giới hạn ~10 reassign calls).
3. **RF testing:** chạy test với RF=1,2,3 để đo replication overhead; đo follower fetch requets per sec. RF=1 là baseline replication-free.
4. **Tune replica paramaters:** nếu CPU quá cao do fetch requests, tăng `replica.fetch.wait.max.ms` / `replica.fetch.min.bytes` để giảm request rate; 
tăng `num.replica.fetchers` nếu muốn parallelize replication (với CPU đủ mạnh). Cẩn thận với `replica.lag.time.max.ms`.
5. **Broker sizing:** Nếu bạn cần lượng partitions lớn $\rightarrow$ scale số broker hoặc nâng loại instance (nhiều cors, network bandwith, disk IOPS).
6. **Avoid many tiny topics:** gộp topics nếu hợp lý để giảm metadata overhead. 


### 8. Commands / operational notes (để thực thi an toàn)

* **Tăng partitions:** `kafka-topics.sh --bootstrap-server <broker> --alter --topic <topic> --partitions <new-count>`
Lưu ý: kafka cho phép tăng partitions nhưng **không giảm**; và tăng lượng lớn có thể gây spike CPU/disk. Hãy tăng theo steps. 

* **Reassign partitions (khi rebalancing cluster):** dùng `kafka-reassign-partitions.sh` / reassignment tool; AWS MSK khuyên không reassign quá nhiều partition trong một lần.


### 9. Thiết kế kiểm thử (experimental methodology) - reproducible

1. **Isolate variables:** cố gắng giữ workload constant; chỉ thay 1 biến (partitions, RF, topics).

2. **Use synthetic producer/consumer:** benchmark tool (kafka-producer-perf-test.sh / consumer perf test) để tạo throughput cố định.

3. **Measure for each point:** CPU per broker, follower fetch rates, UnderReplicatedPartitions, network bytes/sec, GC pauses, filehandles.

4. **Stepwise increase:** +100 partitions / step (hoặc tỷ lệ %) → wait until metrics stable for N minutes.

5. **Repeat for RF values:** RF=1, RF=2, RF=3; keep total partitions constant to study topic vs partition count.

6. **Record leader election time:** kill a broker and measure time for controller to elect leaders and for consumers/producers to recover. (gives real-world recovery beta).


## Key Takeaway

Kafka không dùng cache trong memory kiểu truyền thống mà dựa hoàn toàn vào **file system + OS Page Cache** để lưu message. Cách này giúp vượt trội về throughput, ổn định với lượng data lớn, dễ scale, và giảm áp lực lên JVM GC.

2. Kafka không chỉ đơn thuần là publish/subcribe message broker, mà được tối ưu tới OS-level đến network-level để xử lý hàng triệu message/sec, đặc biệt trong hệ thống multi-tennent, high throughput. Tóm tắt 3 tối ưu của Kafka:
* Zero-copy: `sendfile`, page cache, binary format: Tránh copy dữ liệu nhiều lần, CPU & memory tối ưu, độc gần max network. 
* Batching: Gộp nhiều message vào batch, giảm round-trip, linear disk write, sequential memory access, thoguhtput cao. 
* Batch Compression: Nén các batch trước gửi, lưu compressed, giảm network usage, tiết kiệm disk, nén hiệu quả hơn nén từng message.

3. 