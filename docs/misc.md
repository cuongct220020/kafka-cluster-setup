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


## Kafka and The File System

### Key takeaway
Kafka không dùng cache trong memory kiểu truyền thống mà dựa hoàn toàn vào **file system + OS Page Cache** để lưu message. Cách này giúp vượt trội về throughput, ổn định với lượng data lớn, dễ scale, và giảm áp lực lên JVM GC.



## Batch Processing for Efficiency






### 5. Tóm tắt 3 tối ưu

* **Zero-copy:** `sendfile`, page cache, binary format: Tránh copy dữ liệu nhiều lần, CPU & memory tối ưu, độc gần max network. 
* **Batching:** Gộp nhiều message vào batch, giảm round-trip, linear disk write, sequential memory access, thoguhtput cao. 
* **Batch Compression:** Nén các batch trước gửi, lưu compressed, giảm network usage, tiết kiệm disk, nén hiệu quả hơn nén từng message.

### 6. Key takeaway

Kafka không chỉ đơn thuần là publish/subcribe message broker, mà được tối ưu tới OS-level đến network-level để xử lý hàng triệu message/sec, đặc biệt trong hệ thống multi-tennent, high throughput. Tóm tắt 3 tối ưu của Kafka:


## Kakfa Producer Design

### 1. Producer là gì? 
* Producer là một ứng dụng client gửi dữ liệu (messages) đến Kafka cluster.
* Producer viết dữ liệu trực tiếp vào topic trên broker, không cần bất kỳ layer trung gian nào. 
* Producer chịu trách nhiệm **chọn partition và gửi message.**

### 2. Load Balancing (cân bằng tải) của producer
Cách Kafka cân bằng tải: 

#### Metadata từ broker
* Mỗi broker giữ metadata: 
  * Broker nào đang alive. 
  * Broker nào là leader của partition nào. 
* Producer dùng metadata này để route message trực tiếp tới partition leader. 

#### Partitioning message
* có thể ngẫu nhiên: message được phân phối đều giữa các partition. 
* Hoặc semantic partitioning:
  * Producer có thể gửi message theo key (ví dụ: user ID).
  * Kafka hash key $\rightarrow$ chọn partition. 
  * Ưu điểm: các message của cùng key luôn ở cùng partition, giúp consumer xử lý locality-sensitive (vd: tất cả transaction của 1 user xử lý trên cùng 1 consumer). 

#### Override partition function
* Bạn có thể custom logic chọn partition nếu muốn (ví dụ ưu tiên partition trống, phân phối tải đặc biệt). 

**Lợi ích:**
* Cân bằng tải giữa các broker.
* Consumer có thể dựa vào partition để xử lý dữ liệu hiệu quả, giảm contention. 

### 3. Batching (gộp message)

**Tại sao batching quan trọng?** 
* Gửi message nhỏ lẻ $\rightarrow$ nhiều I/O nhỏ $\rightarrow$ overhead cao. 
* Gộp message thành batch $\rightarrow$ **tăng throughput, giảm I/O**.


**Cách Kakfa producer batching:** 
1. Theo kích thước batch
   * Ví dụ: `batch.size = 64KB`
   * Producer gom message cho đến khi đủ batch size $\rightarrow$ gửi 1 lần
2. Theo thời gian chờ (linger.ms)
   * Ví dụ: `linger.ms =. 10 ms`
   * Producer sẽ đợi tối đa 10ms để gom thêm message vào batch trước khi gửi. 


**Trade-off**
* **Latency vs Throughput:**
  * Delay nhỏ để gom batch $\rightarrow$ tăng throughput
  * Delay quá nhiều $\rightarrow$ tăng latency. 
* Mục tiêu: tối ưu I/O, network, server mà vẫn giữ latency chấp nhận được. 


### 4. kết hợp load balancing + batching
Producer có thể: 
* **Chọn partitio**n dựa trên key $\rightarrow$ locality-sensitive processsing. 
* **Gom batch** theo size hoặc time $\rightarrow$ gửi ít request $\rightarrow$ giảm overhead. 

Kết quả: **high throughtput, efficient load distribution, predictable partitioning.**

## Kafka Consumer Design

### 1. Kafka consumer là gì? 
* **Consumer** là một client ứng dụng đọc và xử lý messages từ Kafka broker. 
* Consumer pull dữ liệu từ partition leader bằng cách gửi **fetch request**. 
* Consumer chỉ định offset để xác định vị trí bắt đầu đọc trong log $\rightarrow$ có thể reconsume dữ liệu nếu cần. 

**Key point:** Consumer kiểm soát tốc độ và vị trí đọc của mình. 

### 2. Pull vs Push Design
* Kafka dùng pull-based design:
  * Producer push data vào broker. 
  * Consumer pull data từ broker. 

**Lợi ích của pull:**
1. Nếu consumer chậm, nó có thể **catch up** mà không bị mất dữ liệu. 
2. Cho phép **batching tối ưu:** consumer đọc nhiều message cùng lúc $\rightarrow$ throughtput cao. 
3. Push-based system khso batch data vì phải đoán consumer có xử lý kịp không $\rightarrow$ dễ dẫn đến latency cao hoặc gửi từng message nhỏ. 

**Tóm tắt:** Pull-based giúp **tối ưu batching, dễ kiểm soát tốc độ.**

### Consumer Groups và Group IDS

Khái niệm: 
* **Consumer Group:** Tập hợp các consumer từ cùng 1 ứng dụng, cùng nhau tiêu thủ message từ topic. 
* **Partition:** Mỗi partition chỉ được 1 consumer trong group đọc tại 1 thời điểm.
* Mỗi consumer trong group có `group.id` giống nhau. 

Cách hoạt động:
1. Khi consumer khởi tạo $\rightarrow$ set group.id $\rightarrow$ subcribe topic. 
2. Broker dùng **Group Coordinator** để:
* Phân phối partition đều cho các consumer. 
* Giữ cân bằng khi consumer join/leave hoặc topic metadata thay đổi. 

Lợi ích: Tự động cân bằng tải, hỗ trợ scale consumer dễ dàng. 

### Rebalance protocol & Partition assignment

* Khi group thay đổi, Kafka dùng rebalance protocol để phân partition:
* 2 loại protocol:
  * **Classic:** leader-based, toàn bộ group pause khi rebalance → disruption cao. 
  * **New:** incremental, broker phân assignment → disruption thấp, efficient hơn

### Tracking Consumer Position: Offsets
Tại sao cần tracking?
* Để biết consumer đọc đến đâu $\rightarrow$ tránh mất dữ liệu hoặc đọc lại quá nhiều.
* Truyền thống: 
  * Broker ghi ngay khi gửi $\rightarrow$ nếu consumer crash $\rightarrow$ mất message. 
  * Broker đợi ACK $\rightarrow$ nếu consumer crash sau khi xử lý nhưng chưa gửi ACK $\rightarrow$ message bị đọc lại. 

**Giải pháp: Consumer offsets**
* **Offset:** Số nguyên xác định **vị trí next message** cần đọc. 
* Stored trong topic `__consumer_offsets`, theo group, partition, consumer. 
* Khi consumer restart $\rightarrow$ đọc offset từ topic này $\rightarrow$ resume từ last commmited position. 

### Kịch bản Crash
* Consumer crash $\rightarrow$ consumer khác takeover partition $\rightarrow$ bắt đầu từ last committed offset

* Consumer mới cần reprocess messages từ offset commit $\rightarrow$ current position của consumer crash.

* Consumer chỉ đọc đến high watermark $\rightarrow$ đảm bảo không đọc dữ liệu chưa replicated.

## Kafka Message Delivery Gurantees (Cơ chế đảm bảo giao nhận thông điệp)

Trong lý thuyết của hệ thống phân tán, vấn đề "đảm bảo giao nhận" (delivery guarantee) xác định bản hợp đồng cam kết giữa hệ thống và người sử dụng về độ bền và tính duy nhất của thông điệp trong bối cảnh
các sự cố phần cứng hoặc mạng là điều không thể tránh khỏi. Apache Kafka hỗ trợ một phổ rộng các cam kết này, cho phép người vận hành đánh đổi giữa độ trệ (latency) và độ an toàn dữ liệu (safety) tuỳ thuộc 
vào yêu cầu nghiệp vụ cụ thể. 

### 1. Phổ quát các ngữ nghĩa giao diện
Kafka cung cấp ba cấp độ ngữ nghĩa giao diện chính, được cấu thành từ sự phối hợp giữa Producer (người gửi), Broker (máy chủ lưu trữ) và Consumer (người nhận). 

#### 1.1. At-Most-Once (Nhiều nhất một lần)
Đây là cấp độ đảm bảo lỏng lẻo nhất, được gọi là "fire-and-forget" (gửi và quên). Trong mô hình này, thông điệp được gửi đi và hệ thống không cam kết rằng nó sẽ được lưu trữ bền vững. Nếu có bất kỳ sự cố nào xảy
ra trong quá trình truyền tải như lỗi mạng, lỗi phân giải DNS, hoặc Broker bị sập - thông điệp sẽ bị mất vĩnh viễn và không có cơ chế tự động gửi lại. 
* **Cơ chế kỹ thuật:** 
  * **Phía Producer** được cấu hình với tham số `ack=0`. Khi phương thức `send()` được gọi, dữ liệu được ghi vào bộ đệm socket mạng (network buffer) và Producer ngay lập tức coi như việc đã gửi thành công
  mà không chờ bất kỳ phản hồi nào từ Broker. 
  * **Phía Consumer**, ngữ nghĩa này đạt được khi Consumer đọc tin nhắn, cam kết (commit) vị trí offset của mình trước khi thực sự xử lý dữ liệu. Nếu consumer gặp sự cố ngay sau 
  khi commit nhưng chưa kịp xử lý, thông điệp đó coi như đã đi qua và bị mất. 
* **Phân tích hiệu năng và ứng dụng:** Mặc dù nghe có vẻ rủi ro, ngữ nghĩa này cung cấp băng thông cao nhất và độ trễ thấp nhất do loại bỏ hoàn toàn chi phí chờ đợi (latency penalty) của các vòng lặp mạng (network round-trip) 
để xác nhận. Nó phù hợp cho các luồng dữ liệu mà việc mất một vài mẫu tin không ảnh hưởng đến bức tranh toàn cảnh, ví dụ như log thu thập chỉ số hệ thống hoặc dữ liệu cảm biến IoT tần suất cao. 

#### 1.2. At-Least-Once (Ít nhất một lần)

Đây là ngữ nghĩa mặc định và phổ biến nhất trong Kafka, đảm bảo không có dữ liệu nào bị mất, nhưng chấp nhận khả năng một số thông điệp có thể bị trùng lặp (duplicated).
* **Cơ chế kỹ thuật:** 
  * **Phía Producer:** Ứng dụng gửi tin nhắn và chờ tín hiệu xác nhận (acknowledgement) từ Broker (`acks=1` hoặc `acks=all`). Nếu Broker ghi dữ liệu thành công nhưng gói tin phản hồi xác nhận bị mất do lỗi mạng, Producer - sau khi
  hết thời gian chờ (timeout) - sẽ lầm tưởng rằng việc gửi thất bại và thực hiện gửi lại (retry) thông điệp đó. Điều này dẫn đến việc cùng một nội dung thông điệp được ghi hai lần vào log với hai offset khác nhau.
  * **Phía Consumer:** Consumer nhận một lô (batch) tin nhắn, xử lý nghiệp vụ, và chỉ cam kết commit offset sau khi việc xử lý hoàn tất. Nếu consumer bị sập sau khi xử lý xong nhưng trước khi kịp commit offset, instance Consumer thay thế
  sẽ đọc lại đúng lô tin nhắn đó từ offset đã cam kết cuối cùng, dẫn đến việc xử lý lại dữ liệu.
* **Hệ quả:** Để sử dụng mô hình này an toàn, các hệ thống hạ nguồn (downstream system) cần phải được thiết kế với tính chất idempotent (luỹ đẳng), tức là khả năng xử lý cùng một đầu vào nhiều lần không làm thay đổi kết quả cuối cùng của hệ thống. 

#### 1.3. Exactly-Once (Chính xác một lần)

Trong lịch sử, việc đạt được ngữ nghĩa "Chính xác một lần" trong hệ thống phân tán được coi là một thách thức cực đại, thường phải đánh đổi bằng hiệu năng rất thấp. Tuy nhiên, từ phiên bản 0.11, Kafka đã giới thiệu khả năng này thông qua sự kết hợp của
hai cơ chế phức tạp: **Idempotent Producer** và **Transactional API**. Điều này không đảm bảo gói tin chỉ đi qua mạng một lần, mà đảm bảo rằng tác động của thông điệp lên trạng thái hệ thống chỉ được ghi nhận dúng một lần, ngay cả khi có sự cố xảy ra.

* **Idempotent Producer: Giải quyết vấn đề trùng lặp:** Idempotent Producer là lớp bảo vệ đầu tiên, giải quyết vấn đề trùng lặp do việc gửi lại (retry) của Producer khi gặp lỗi mạng tạm thời. 
  * **Kiến trúc định danh:** Để thực hiện điều này, Producer khi khởi động sẽ được Broker gán một định danh duy nhất gọi là Producer ID (PID). PID này hoàn toàn trong suốt với người dùng và được quản lý nội bộ. 
  * **Quản lý tuần tự (Sequence Number):** Mỗi lô thông điệp (RecordBatch) gửi đến một phân vùng (partition) cụ thể sẽ được gắn kèm một số thự tự (Sequence Number) tăng dần đơn điệu, bắt đầu từ 0. Broker duy trì một bản đồ trạng thái `(PID, Topic, Partition) -> LastSequenceNumber` trong bộ nhớ và bền vững hoá vào log.
  * **Logic loại bỏ trùng lặp:** Khi Broker nhận được một lô tin nhắn:
    * Nếu `IncomingSeq == LastSeq + 1`: Chấp nhận và ghi vào log. Cập nhật `LastSeq`.
    * Nếu `IncomingSeq <= LastSeq`: Phát hiện trùng lặp (do Producer gửi lại). Broker trả về xác nhận thành công ngay lập tức mà không ghi thêm vào log. 
    * Nếu `IncomingSeq > LastSeq + 1`: Phát hiện mất dữ liệu. Broker từ chối lô tin nhắn vớ lỗi `OutOfOrderSequenceException`, buộc Producer phải xử lý lại.
  * **Cấu hình tối ưu:** Từ Kafka 3.0, `enable.idempotence` mặc định là `true`. Cấu hình này tự động ép buộc `acks=all` và `retries=MAX_VALUE`. 
  Một tham số quan trọng là `max.in.flight.requests.per.connection`, cần được thiết lập nhỏ hơn hoặc bằng 5 để đảm bảo thứ tự gửi và được giữ nguyên ngay cả khi có retry. 

* **Transactional Semantics: Giao dịch Nguyên tử trên Đa phân vùng:**
                                            
Trong khi Idempotence giải quyết vấn đề của một Producer đơn lẻ ghi vào một partition, các ứng dụng xử lý luồng (Stream Processing) thường hoạt động theo mô hình "Consume-Process-Produce": đọc từ Topic A, xử lý, và ghi kết quả sang Topic B. Nếu ứng dụng sập sau khi ghi sang B nhưng chưa commit offset ở A, dữ liệu sẽ bị xử lý đúp. Kafka Transactions cung cấp cơ chế ghi nguyên tử (atomic write) trên nhiều phân vùng và topic khác nhau: hoặc tất cả đều thành công, hoặc không có gì được ghi nhận.   

* **Giao thức Transaction:** Kafka sử dụng một biến thể của giao thức Two-Phase Commit (2PC) nhưng được tối ưu hóa cho log-structured storage.

  * **Transactional ID:** Người dùng phải cung cấp một transactional.id cố định. Khác với PID sinh ngẫu nhiên, ID này bền vững qua các lần khởi động lại ứng dụng, cho phép hệ thống nhận diện và phục hồi các giao dịch bị treo của các instance cũ.   

  * **Transaction Coordinator:** Một module chạy trên Broker đóng vai trò điều phối. Trạng thái của mọi giao dịch được lưu trữ trong một topic nội bộ đặc biệt tên là __transaction_state.

  * **Luồng thực thi:**

    * **Init:** Producer đăng ký transactional.id. Coordinator sẽ tăng epoch của ID này, cô lập (fence) bất kỳ Producer cũ nào (zombie) đang dùng cùng ID.   

    * **Begin & Produce:** Producer bắt đầu giao dịch và gửi tin nhắn. Các tin nhắn này được ghi ngay vào log của các topic đích nhưng được đánh dấu là chưa cam kết (uncommitted).

    * **Send Offsets:** Producer gửi thông tin offset của consumer group (cho việc đọc đầu vào) đến Coordinator. Điều này tích hợp việc commit offset vào trong cùng một giao dịch với việc ghi dữ liệu đầu ra.   

    * **Commit/Abort:** Khi Producer gọi commitTransaction(), Coordinator thực hiện quy trình 2 pha:

      * **Pha 1:** Ghi trạng thái PREPARE_COMMIT vào __transaction_state.
  
      * **Pha 2:** Ghi các "Commit Marker" (một loại Control Record đặc biệt, không chứa dữ liệu người dùng) vào tất cả các partition tham gia giao dịch. Sau đó ghi trạng thái COMPLETE_COMMIT vào log giao dịch.   

* **Mức độ cô lặp (Isolation levels):** Về phía Consumer, tính năng này được kiểm soát bởi cấu hình `isolation.level`:
  * `read_uncommited` (mặc định): Consumer nhìn thấy mọi tin nhắn, kể cả những tin nhắn thuộc giao dịch đang mở hoặc đã bị huỷ (aborted).
  * `read_commited`: Consumer chỉ nhìn thấy các tin nhắn đã được commit thành công. Consumer sẽ đệm các tin nhắn trong bộ nhớ cho đến khi gặp một "Commit Marker". Vị trí an toàn cuối cùng mà Consumer có thể đọc được gọi là LSO (Last Stable Offset)

  
## Kafka Log Compaction
Kafka thường được biết đến với chính sách lưu trữ theo thời gian (ví dụ: giữ dữ liệu 7 ngày). Tuy nhiên, đối với các trường hợp sử dụng như lưu trữ trạng thái (state stores) hay bảng tham chiếu, 
người dùng chỉ quan tâm đến giá trị mới nhất của một khóa (key) chứ không phải lịch sử thay đổi của nó. Log Compaction là tính năng biến Kafka thành một kho lưu trữ Key-Value bền vững.

### 1. Nguyên lý Hoạt động
Log Compaction đảm bảo rằng Kafka sẽ luôn giữ lại ít nhất là bản ghi cuối cùng (latest state) cho mỗi khóa tin nhắn, loại bỏ các bản ghi cũ hơn có cùng khóa.   

* **So sánh:** Nếu topic thường giống như một file log chứa chuỗi các lệnh INSERT, thì compacted topic giống như một bảng Database hiện tại (snapshot) sau khi thực hiện chuỗi lệnh UPSERT. 
Nếu người dùng cập nhật địa chỉ email 5 lần, Log Compaction sẽ xóa 4 lần trước và chỉ giữ lại địa chỉ mới nhất.   

### 2. Cấu trúc Log và Quá trình Dọn dẹp
Log của một partition được chia thành hai phần logic:

1. **Phần Đầu (Head):** Chứa các segment đang hoạt động (active segments) nơi dữ liệu mới được ghi vào. Phần này tuân theo offset tuần tự và chưa được nén.

2. **Phần Đuôi (Tail):** Chứa các segment cũ đã được nén. Tại đây, các khóa là duy nhất (về cơ bản).   

**Quá trình Nén (Cleaning Process):** Một luồng nền gọi là **Log Cleaner** sẽ thực hiện công việc này:

* Nó quét phần Head (dữ liệu bẩn) để xây dựng một **Offset Map (Bản đồ Offset)** trong bộ nhớ, ánh xạ mỗi Key tới Offset mới nhất của nó (Key -> LatestOffset). Kích thước của map này phụ thuộc vào cấu hình log.cleaner.dedupe.buffer.size.   

* Sau đó, nó sao chép lại các log segment từ đầu. Với mỗi bản ghi, nó kiểm tra trong Offset Map. Nếu offset của bản ghi nhỏ hơn offset trong Map (tức là đã có phiên bản mới hơn), bản ghi đó sẽ bị bỏ qua (xóa). Nếu khớp, nó được chép sang segment mới (Swap Segment).   

* Quá trình này tốn tài nguyên I/O và CPU, do đó cần được cấu hình cẩn thận để không ảnh hưởng đến hiệu năng của Producer/Consumer.

### 3. Xử lý Xóa dữ liệu (Tombstones)
Làm thế nào để xóa hoàn toàn một khóa khỏi hệ thống khi cơ chế nén luôn giữ lại giá trị cuối cùng?

* **Tombstone (Bia mộ):** Producer gửi một tin nhắn với Key xác định và Value = null.

* **Ý nghĩa:** Tin nhắn này đóng vai trò như một lệnh DELETE. Khi Consumer đọc được tombstone, nó biết cần xóa khóa đó khỏi bộ nhớ cục bộ.

* **Delete Retention:** Bản thân Tombstone cũng cần được lưu trữ một thời gian để đảm bảo mọi Consumer (kể cả những Consumer đang offline) đều có cơ hội đọc được lệnh xóa này. Thời gian này được quy định bởi delete.retention.ms (mặc định 24 giờ). Sau thời gian này, Tombstone sẽ bị cơ chế Compaction xóa bỏ hoàn toàn.   

### 4. Các Trường hợp Sử dụng Điển hình
* **Kafka Streams / KTables:** Các ứng dụng cần khôi phục trạng thái cục bộ sau khi khởi động lại sẽ đọc từ compacted topic để nạp lại dữ liệu vào bộ nhớ (cache hydration) mà không cần xử lý lại toàn bộ lịch sử.   

* **Change Data Capture (CDC):** Đồng bộ dữ liệu từ Database. Compacted topic đóng vai trò như một bản sao của bảng Database, đảm bảo kích thước topic không tăng trưởng vô hạn theo thời gian.   

* **Cấu hình Động:** Lưu trữ các cấu hình hệ thống, nơi chỉ có giá trị cấu hình hiện tại là quan trọng.


## Cơ chế Group Coordinator và quy trình quản lý Consumer Group

### 1. Cơ chế tìm kiếm coordinator (Discovery)

Trước khi một Consumer có thể gia nhập nhóm, nó phải biết ai là người quản lý mình.

* **Xác định Coordinator:** Khi một consumer khởi động, nó gửi yêu cầu `FindCoordinator` kèm theo `group.id` tới bất kỳ broker nào.
* **Thuật toán hash:** Broker nhận yêu cầu sẽ tính toán để tìm ra phân vùng (partition) cụ thể của topic nội bộ `__consumer_offsets` sẽ chịu trách nhiệm cho nhóm này. Công thức thường là:
  $$\text{Partition} = \text{hash}(\text{group.id}) \% \text{num_partitions_offsets_topic}$$  
* **Vai trò Coordinator:** Broker nào đang giữ vai trò **Leader** của phân vùng `__consumer_offsets` vừa tìm được sẽ trở thành **Group Coordinator** cho consumer group đó. 
Điều này đảm bảo tải quản lý các nhóm được chia đều cho các broker trong cụm. 

### 2. Quá trình gia nhập và phân chia (The rebalance protocol)

Đây là "điệu nhảy logistic" (logistical dance) được nhắc đến trong tài liệu, nơi quyền lực được chia sẻ giữa Broker (Coordinator) và Client (Group Leader). 

* **Bước 1: JoinGroup (Gia nhập)**
  * Tất cả consumer gửi yêu cầu `JoinGroup` tới Coordinator. 
  * Coordinator chọn một consumer làm **Group Leader** (thường là consumer đầu tiên gửi yêu cầu).
  * Coordinator trả về danh sách tất cả các thành viên trong nhóm và thông tin đăng ký (subcription) cho **Group Leader**, nhưng chỉ trả về `MemberId` cho các Consumer khác (Followers).
* **Bước 2: Phân chia Partition (Assignment)**
  * Đây là điểm độc đáo của Kafka: **Broker không quyết định consumer nào nhận partition nào.** Việc này do **Group Leader** thực hiện. 
  * **Group Leader** sử dụng thuật toán phân chia đã cấu hình (như Range Assignor, Round Robin hay Sticky Assignor) để lập bản đồ phân chia partition cho từng thành viên. 
Việc đẩy logic này xuống client giúp Kafka linh hoạt hỗ trợ các chiến lược phân chia tuỳ chỉnh mà không cần khởi động lại Broker. 
* **Bước 3: SyncGroup (Đồng bộ)**
  * Group Leader gửi yêu cầu `SyncGroup` chứa bảng phân chia hàon chỉnh tới Coordinator. 
  * Các Consumer khác cũng gửi `SyncGroup` nhưng không kèm dữ liệu phân chia. 
  * Coordinator nhận bảng phân chia từ Leader và phân phát lại nhiệm vụ cụ thể cho từng consumer thông qua phản hồi của `SyncGroup`. 
Lúc này, quá trình rebalance kết thúc và consumer bắt đầu đọc dữ liệu. 


### 3. Quản lý Offset (Offset Management)
Kafka không lưu trạng thái đọc trên RAM của Broker mà lưu vào một topic đặc biệt để đảm bảo độ bền. 
* **Commit Offset:** Khi consumer xử lý xong dữ liệu, nó gửi `CommitOffsetRequest` tới Coordinator. 
Coordinator ghi thông tin này vào topic `__consumer_offsets`. Topic này thường được cấu hình **Log Compaction** để chỉ giữ lại offset mới nhất, giúp tiết kiệm dung lượng.
* **Khôi phục (restart):** Khi Consumer khởi động lại, nó gửi `OffsetFetchRequest` để lấy lại vị trí đọc cuối cùng. Nếu chưa có offset nào được lưu (consumer mới), cấu hình
`auto.offset.reset` (earliest/lastest) sẽ quyết định điểm bắt đầu.


### 4. Khả năng chịu lỗi (Fault Tolerance)
Hệ thống Coordinator thừa hưởng tính năng chịu lỗi của chính Kafka Topic. 
* Vì `__consumer_offsets` là một topic được sao chép (replicated) như mọi topic khác, nếu Broker đóng vai trò Coordinator bị lỗi, một trong các bản sao (Follower) của phân vùng
`__consumer_offsets` đó sẽ được bầu làm Leader mới và tự động trở thành Coordinator mới. 
* Consumer sẽ nhận biết sự thay đổi này khi cố gắng liên lạc với Coordinator cũ thất bại và sẽ thực hiện lại quy trình `FindCoordinator`. 


### 5. Tái cân bằng (Rebalance Triggers)
Consumer Group không cố định mà rất động. Quá trình Rebalance (lặp lại các bước Join và Sync) sẽ được kích hoạt khi: 
* **Thay đổi thành viên:** Có Consumer mới tham gia hoặc Consumer cũ rời đi (shutdown hoặc crash/timeout hearbeat).
* **Thay đổi topic:** Số lượng partition của topic thay đổi hoặc topic mới được tạo ra khớp với mẫu đăng ký (regex subscription) của nhóm.

Tóm lại, kiến trúc này tách biệt rõ ràng trách nhiệm: **Group Coordinator** (Broker) quản lý thành viên và trạng thái offset, 
trong khi **Group Leader** (client) quản lý logic phân chia dữ liệu. Điều này giúp Kafka vừa duy trì được sự ổn định của hệ thống phân tán,
vừa linh hoạt trong logic nghiệp vụ. 

### 6. Sự tiến hoá của giao thức tái cân bằng

#### 6.1. Stop-the-World Rebalance (Cơ chế cũ - Eager Rebalance)

Đây là cách tiếp cận truyền thống (mặc định trước Kafka 2.4). Khi một consumer mới tham gia hoặc một consumer cũ rời đi, **toàn bộ nhóm** sẽ bị dừng lại. 
* **Cơ chế:**
  1. Coordinator gửi tín hiệu Rabalance.
  2. Tất cả Consumer buộc phải **thu hồi (revoke)** toàn bộ các phân vùng đang nắm giữ. 
  3. Tất cả tham gia lại nhóm (`JoinGroup`) và đợi phân chia lại (`SyncGroup`).
  4. Consumer nhận phân vùng mới và bắt đầu xử lý lại từ đầu. 
* **Vấn đề 1 - Rebuilding State (Xây dựng trạng thái):** Nếu consumer 1 đang xử lý partition `p0` và có bộ nhớ đệm (cache/state) cho nó. Trong cơ chế cũ nó phải xoá
cache này đi. Sau khi rebalance, nếu nó may mắn được gán lại đúng `p0`, nó lại phải tốn tài nguyên để xây dựng lại cache đó từ đầu. Đây là sự lãng phí vô ích. 
* **Vấn đề 2 - Paused Processing (Ngừng xử lý):** Trong suốt quá trình rebalance (có thể mất vài giây đến vài phút với nhóm lớn), không có consumer nào làm việc cả. Hệ thống bị đóng băng (Stop-the-world).


#### 6.2. StickyAssigner (Cải thiện thuật toán phân chia)
`StickyAssignor` là một thuật toán phân chia thông minh hơn `Range` hay `RoundRobin`.
* **Mục tiêu:** Giữ cho sự thay đổi phân vùng là ít nhất (sticky - dính chặt). Nếu Consumer 1 đang giữ `p0`, thuật toán sẽ ưu tiên giữ nguyên `p0` cho Consumer 1 trong lần phân chia tới. 
* **Lợi ích:** Giúp giảm thiểu vấn đề "Rebuilding State". Vì consumer thường được nhận lại đúng phân vùng cũ, nó không cần xoá và xây lại cache địa phương. Tuy nhiên, nếu dùng với giao thức cũ (Eager), nó vẫn phải tạm dừng hoạt động. 

#### 6.3. Cooperative Rebalance (Giao thức hợp tác - KIP429)

Đây là bước tiến lớn (từ Kafka 2.4+), thay đổi cách thực hiện rebalance từ "làm tất cả một lần" sang "làm từng bước nhỏ" (incremental).

* **Cơ chế 2 bước:**
  * **Bước 1:** Khi thay đổi, Coordinator tính toán xem phân vùng nào thực sự cần di chuyển. Ví dụ: `p2` cần chuyển từ Consumer 1 sang Consumer 3 (mới vào). Consumer 1 chỉ bị thu hồi quyền với `p2`. Trong lúc đó, Consumer 1 vẫn tiếp tục xử lý `p0` mà không bị gián đoạn.
  * **Bước 2:** Phân vùng `p2` sau khi được thu hồi sẽ được gán cho Consumer 3. 
* **Lợi ích:** "world does not stop" (Thế giới không ngừng quay). Những consumer không bị ảnh hưởng bởi việc di chuyển partition vẫn hoạt động bình thường. Hệ thống ổn định hơn rất nhiều. 


#### 6.4. Static Group Membership (Thành viên tĩnh)
Đây là giải pháp tối ưu cho các trường hợp bảo trì định kỳ (như Rolling Restart trên Kubernetes).

* **Cơ chế:** Bình thường, mỗi khi consumer khởi động lại, nó được cấp một ID mới (dynamic ID) và Coordinator coi nó là thành viên mới -> Kích hoạt Rebalance. Với **Static Membership**, bạn cấu hình `group.instance.id` cố định cho consumer.
* **Lợi ích:**
  * Khi Consumer 1 (có static ID) bị restart nhanh (trong khoảng `session.timeout.ms`), Coordinator biết rằng "anh này chỉ vắng mặt chút thôi".
  * Coordinator **không kích hoạt Rebalance**. Các phân vùng của Consumer 1 được giữ nguyên trạng thái chờ.
  * Khi Consumer 1 quay lại, nó tiếp tục công việc ngay lập tức mà không gây xáo trộn cho cả nhóm.

Tóm lại: Nôi dung trên mô tả quá trình tối ưu hoá Kafka Consumer: từ việc **"dừng tất cả, xoá tất cả làm lại"** (Stop-the-World) $\rightarrow$ **"giữ nguyên vị trí tối đa"** (Sticky) $\rightarrow$ **"chỉ dừng những gì cần di chuyển"** (Cooperative) $\rightarrow$ và cuối cùng **"không dừng gì cả khi restart nhanh"** (Static Membership)










