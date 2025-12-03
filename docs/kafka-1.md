# Apache Kafka Basic

## Mục lục

<!-- TOC -->
  * [Mục lục](#mục-lục)
  * [1. Giới thiệu: Sự Chuyển dịch Mô hình sang Nhật ký Phân tán (Distributed Log)](#1-giới-thiệu-sự-chuyển-dịch-mô-hình-sang-nhật-ký-phân-tán-distributed-log)
    * [1.1. Vấn đề nguyên thuỷ: Ma trận tích hợp N x M](#11-vấn-đề-nguyên-thuỷ-ma-trận-tích-hợp-n-x-m)
    * [1.2. Nhật ký (Log) so với hàng đợi (Queue) và cơ sở dữ liệu (Database)](#12-nhật-ký-log-so-với-hàng-đợi-queue-và-cơ-sở-dữ-liệu-database)
  * [2. Giải phẫu kiến trúc dữ liệu (Data Plane Architecture)](#2-giải-phẫu-kiến-trúc-dữ-liệu-data-plane-architecture)
    * [2.1. Partition: Đơn vị của sự song song và thứ tự](#21-partition-đơn-vị-của-sự-song-song-và-thứ-tự)
    * [2.2. Cấu trúc vật lý Segment (phân đoạn)](#22-cấu-trúc-vật-lý-segment-phân-đoạn)
    * [2.3. Vòng đời dữ liệu: Log Rolling vs Retention](#23-vòng-đời-dữ-liệu-log-rolling-vs-retention)
  * [3. Data Plane: Cơ chế Producer và chiến lược phân vùng](#3-data-plane-cơ-chế-producer-và-chiến-lược-phân-vùng)
    * [3.1. Phân bổ Partition: Key vs. Sticky Partitioner](#31-phân-bổ-partition-key-vs-sticky-partitioner)
      * [Trương hợp 1: Có khoá (Key-based Partitioning)](#trương-hợp-1-có-khoá-key-based-partitioning)
      * [Trường hợp 2: Không có khoá (Sticky Partitioner - KIP-480)](#trường-hợp-2-không-có-khoá-sticky-partitioner---kip-480)
    * [3.2. Cơ chế Batching và Request Purgatory](#32-cơ-chế-batching-và-request-purgatory)
  * [4. Control Plane: Từ Zookeeper đến Kraft (KIP-500)](#4-control-plane-từ-zookeeper-đến-kraft-kip-500)
    * [4.1. Hạn chế cốt lõi của Kiến trúc Zookeeepr](#41-hạn-chế-cốt-lõi-của-kiến-trúc-zookeeepr)
    * [4.2. Metadat như một nhật ký (The Log of ALl Logs)](#42-metadat-như-một-nhật-ký-the-log-of-all-logs)
    * [4.3. Cơ chế truyền tải Metadata: Push vs. Pull](#43-cơ-chế-truyền-tải-metadata-push-vs-pull)
    * [4.4. Snapshotting trong KRaft](#44-snapshotting-trong-kraft)
  * [5. Cơ chế sao chép (Replication) và Đảm bảo dữ liệu](#5-cơ-chế-sao-chép-replication-và-đảm-bảo-dữ-liệu)
    * [5.1. In-Sync Replicas (ISR)](#51-in-sync-replicas-isr)
    * [5.2. High Watermark (HW) và Leader Epoch: Ngăn chặn mất dữ liệu và phân kỳ](#52-high-watermark-hw-và-leader-epoch-ngăn-chặn-mất-dữ-liệu-và-phân-kỳ)
  * [6. Delivery Semantics: Exactly-Once (EOS)](#6-delivery-semantics-exactly-once-eos)
    * [6.1. Idempotent Producer (Producer luỹ đẳng)](#61-idempotent-producer-producer-luỹ-đẳng)
    * [6.2. Transactional API (Giao dịch Đa phân vùng)](#62-transactional-api-giao-dịch-đa-phân-vùng)
  * [7. Cơ chế Consumer và Tái cân bằng (Rebalancing)](#7-cơ-chế-consumer-và-tái-cân-bằng-rebalancing)
    * [7.1. Offset Management: `__consumer_offsets`](#71-offset-management-__consumer_offsets)
    * [7.2. Các giao thức Rebalancing: Từ Eager đến Cooperative](#72-các-giao-thức-rebalancing-từ-eager-đến-cooperative)
  * [8. Tối ưu hoá phần cứng và tích hợp hệ điều hành](#8-tối-ưu-hoá-phần-cứng-và-tích-hợp-hệ-điều-hành)
    * [8.1. Zero-Copy và `sendfile`](#81-zero-copy-và-sendfile)
    * [8.2. Sequential I/O và Page Cache](#82-sequential-io-và-page-cache)
    * [8.3. Lựa chọn phần cứng SSD vs HDD](#83-lựa-chọn-phần-cứng-ssd-vs-hdd)
  * [9. Tổng kết và kiến nghị](#9-tổng-kết-và-kiến-nghị)
<!-- TOC -->


## 1. Giới thiệu: Sự Chuyển dịch Mô hình sang Nhật ký Phân tán (Distributed Log)

Trong lịch sử phát triển của kiến trúc phần mềm, hiếm có hệ thống nào tạo ra sự thay đổi mô hình (paradigm shift) sâu sắc như Apache Kafka. Xuất phát điểm từ đội ngũ kỹ thuật của LinkedIn vào năm 2010, Kafka không được thiết kế để trở thành một hệ thống hàng đợi tin nhắn (message queue) truyền thống như RabbitMQ hay ActiveMQ, mà được định hình lại từ nguyên lý căn bản của dữ liệu: Nhật ký (The Log).   

Báo cáo này cung cấp một phân tích tường tận, từ khái niệm A-Z đến các cơ chế nội tại (internals) sâu nhất của Kafka, nhằm phục vụ nhu cầu nắm bắt kiến thức nền tảng trước khi triển khai thực tế. Chúng ta sẽ giải phẫu Kafka không chỉ như một công cụ, mà như một hệ quản trị dữ liệu dòng (streaming data platform) với các đảm bảo toán học về tính nhất quán và độ bền vững.

### 1.1. Vấn đề nguyên thuỷ: Ma trận tích hợp N x M

Trước khi Kafka ra đời, các hệ thống dữ liệu doanh nghiệp thường rơi vào tình trạng 
"mỳ ý" (spaghetti architecture). Việc kết nối N nguồn dữ liệu (databases, log files, sensor data)
với M hệ thống đích (Hadoop, Data Warehouse, Search Index) tạo ra độ phức tạp kết nối O(N x M). 
Mỗi đường ống (pipeline) này đòi hỏi các giao thức, định dạng và cơ chế xử lý lỗi riêng biệt, 
dẫn dến sự thiếu nhất quán và khó mở rộng. 

Jay Kreps và các cộng sự tại Linkedin đã nhận ra rằng sự trừu tướng hoá còn thiếu không phải là một
hàng đợi phức tạp, mà là cơ chế lưu trữ đơn giản, bất biến theo thời gian. Đây là lý do Kafka được xây 
dựng dựa trên khái niệm **Commit Log** (Nhật ký cam kết) - một chuỗi các bản ghi chỉ có thể thêm vào (append-only)
và được sắp xếp hoàn toàn theo thời gian. 

### 1.2. Nhật ký (Log) so với hàng đợi (Queue) và cơ sở dữ liệu (Database)

Sự khác biệt triết học này dẫn đến các đặc tính kỹ thuật vượt trội:
* **Khác biệt hàng đợi:** Trong các hệ thống như RabbitMQ (mô hình đẩy - push), tin nhắn thường bị
xoá ngay sau khi tiêu thụ (acknowledgment). Ngược lại, Kafka lưu trữ dữ liệu bền vững (durable retention) 
bất kỳ việc tiêu thụ hay chưa, biến nó thành một "bộ nhớ" của hệ thống thay vì chỉ là một đường ống dẫn. 

* **Khác biệt với cơ sở dữ liệu:** Trong khi RDBMS tối ưu hoá cho các truy vấn ngẫu nhiên (random access) 
và cập nhật trạng thái hiện tại (mutability), Kakfa tối ưu hoá cho thông lượng tuần tự (sequential throughput)
và lịch sử sự kiện (immutability). Kafka coi trạng thái hiện tại của cơ sở dữ liệu chỉ là hệ quả của việc "phát lại"
(replay) toàn bộ nhất ký giao dịch.


## 2. Giải phẫu kiến trúc dữ liệu (Data Plane Architecture)

Để hiểu sâu về hiệu năng của Kafka, cần phải xem xét cách hệ thống này tổ chức dữ liệu vật lý trên đĩa cứng. 
Mặc dù khái niệm logic là **Topic**, đơn vị vật lý thực sự chi phối khả năng mở rộng và song song hoá là **Partition**. 

### 2.1. Partition: Đơn vị của sự song song và thứ tự
Một Topic trong Kafka được chia nhỏ thành nhiều Partitions. Mỗi Partition là một nhất ký commit bất biến và có thứ tự riêng biệt. 

* **Tính chất:** Partition là đơn vị nhỏ nhất để phân phối dữ liệu qua các Broker (máy chủ). Điều này cho phép Kafka mở rộng khả 
năng ghi (write scalability) theo chiều ngang.

* **Offset:** Các bản ghi trong Partition được gán một số định danh tuần tự gọi là Offset. Offset là duy nhất và tăng dần đơn điệu 
trong phạm vi một Partitiion. Kafka **không** đảm bảo thứ tự trên toàn bộ Topic, chỉ đảm bảo trong từng Partition. 

Sự thiết kế này dẫn đến một sự đánh đổi (trade-off) quan trọng. Để đảm bảo thứ tự xử lý tuyệt đối cho một nhóm sự kiện liên quan 
(ví dụ: các giao dịch của cùng một User ID), chúng phải được gửi vào cùng một Partition.   

### 2.2. Cấu trúc vật lý Segment (phân đoạn)
Một Partition không được lưu trữ dưới dạng một tệp tin khổng lồ duy nhất, vì điều này sẽ gây khó khăn cho việc quản lý dung lượng
(retention) và xoá dữ liệu cũ. Thay vào đó, Partition được chia nhỏ thành các **Segment** (phân đoạn). 

Mỗi Segment được đại diện bởi một thư mục chứa ba loại tệp tin chính:
1. **Tệp** `.log`: Chứa dữ liệu thực tế của tin nhắn (payload). Dữ liệu được ghi nối đuôi (append) liên tục. 
2. **Tệp** `.index`: Chứa chỉ mục ánh xạ từ **Offset** sang vị trí vật lý (byte position) trong tệp `.log`. 
3. **Tệp** `.timeindex`: Chứa ánh xạ từ **Timestamp** sang **Offset**, phục vụ cho việc tìm kiếm dữ liệu theo thời gian. 

Cơ chế chỉ mục thưa (Sparse Indexing) và Tìm kiếm

Kafka không duy trì chỉ mục cho mọi tin nhắn vì sẽ tốn quá nhiều RAM. Thay vào đó, Kafka sử dụng **Sparse Index** (Chỉ mục thưa). 
Mặc định, một mục chỉ mục (index entry) chỉ được ghi sau mỗi 4KB dữ liệu (cấu hình `log.index.interval.bytes`). 
Quy trình tìm kiếm một tin nhắn tại Offset X:
1. **Binary Search trên File List:** Kafka tìm Segment chứa Offset X dựa trên tên file (tên file là offset bắt đầu của segment).
2. **Binary Search trong** `.index`: Kafka tải file `.index` (thường nằm trong Page Cache) và tìm vị trí offset lớn nhất nhưng nhỏ hơn hoặc bằng X. 
3. **Sequential Scan trong** `.log`: Từ vị trí byte tìm được, Kafka thực hiện quét tuần tự trong file `.log` để tìm chính xác tin nhắn X. 

Cơ chế này đảm bộ độ phức tạp tím kiếm là O(logN) cho việc xác định vị trí gần đúng và O(1) cho việc đoạn ngắn còn lại, đồng thời tối ưu hoá việc sử dụng bộ nhớ. 

### 2.3. Vòng đời dữ liệu: Log Rolling vs Retention

Dữ liệu được ghi vào "Active Segment". Khi Segment này đạt giới hạn kích thước (`log.segment.bytes`, mặc định 1GB) hoặc thời gian, 
nó sẽ được đóng (rolled) thành chế độ chỉ đọc (read-only) và một Active Segment mới được tạo ra. 

Chính sách **Retention** hoạt động trên mức độ Segment:
* **Delete Policy:** Khi Segment cũ vượt qua thời gian lưu trữ (ví dụ: 7 ngày) hoặc kích thước tổng quy định, toàn bộ file Segment sẽ bị xoá hoặc
unlink khỏi hệ thống tệp. Đây là thao tác chi phí thấp O(1). 
* **Compact Policy:** Đối với Topic lưu trữ trạng thái (như `__consumer_offsets`), Kafka sử dụng Log Compaction. Quá trình này chạy ngầm, loại bỏ các bản ghi cũ nếu 
đã có bản ghi mới hơn cùng khoá (Key). Kết qủa là Kafka giữ lại "trạng thái cuối cùng" của mỗi khoá, biến Partition thành một bảng Hash phân tán bền vững. 

## 3. Data Plane: Cơ chế Producer và chiến lược phân vùng

Phía Producer của Kafka không đơn thuần là một ứng dụng gửi tin nhắn, mà là một hệ thống phức tạp với bộ đệm (accumulator), nén và các thuật toán 
định tuyến thông minh để tối ưu hoá thông lượng mạng. 

### 3.1. Phân bổ Partition: Key vs. Sticky Partitioner

Quyết định tin nhắn sẽ nằm ở Partition nào ảnh hướng trực tiếp đến thứ tự xử lý và sự cân bằng tải của hệ thống.

#### Trương hợp 1: Có khoá (Key-based Partitioning)
Nếu tin nhắn có khoá (key), Producer sử dụng thuật toán băm (mặc định là murmur2) để ánh xạ khoá vào một Partition cố định:

```
Partition = hash(Key) (mod NumPartitions)
```

Điều này đảm bảo tính "locality": tất cả dữ liệu liên quan đến một thực thể (ví dụ: `Customer_ID`) luôn đi vào cùng một Partition và được xử lý tuần tự. 

#### Trường hợp 2: Không có khoá (Sticky Partitioner - KIP-480)

Trước phiên bản 2.4, nếu không có Key, Producer phân phối round-robin từng tin nhắn. Điều này gây ra vấn đề phân mảnh: mỗi Partition nhận một lượng nhỏ dữ liệu,
dẫn đến các batch (lô) nhỏ, giảm hiệu quả nén và tăng số lượng request (latency cao). 

Từ Kafka 2.4, **Sticky Partitioner** được giới thiệu để giải quyết vấn đề này:
* **Cơ chế:** Producer sẽ "dính" (stick) vào một Partition ngẫu nhiên và gửi toàn bộ các tin nhắn không khoá vào đó cho đến khi: 
1. Batch hiện tại đầy (`batch.size`)
2. Hoặc thời gian chờ tối đa kết thúc (`linger.ms`)
* **Lợi ích:** Cơ chế này toạ ra các batch lớn hơn đáng kể, giảm số lượng RPC gửi tới Broker, giảm CPU overhead và độ trễ (latency),
trong khi vẫn đảm bảo phân phối dữ liệu theo thời gian. 

### 3.2. Cơ chế Batching và Request Purgatory

Producer không gửi từng tin nhắn riêng lẻ (trừ khi cấu hình ép buộc). Dữ liệu được tích luỹ vào `RecordAccumulator` trong bộ nhớ. 
Một luồng riêng biệt (I/O Thread) sẽ lấy các batch này và gửi đi. 

Tham số `acks` (acknowledgments) quyết định độ bền vững:
* `acks=0`: Gửi và quên (Fire and forget). Rủi ro mất dữ liệu cao nhất, thông lượng cao nhất. 
* `acks=1`: Leader ghi thành công vào log cục bộ. An toàn trung bình. 
* `acks=all` (hoặc `acks=-1`): Leader chờ tất cả các bản sao trong ISR (In-Sync Replicas) xác nhận. An toàn tuyệt đối.

Khi `acks=all`, request từ Producer sẽ được đưa vào một cấu trúc gọi là `Purgatory` (nơi thanh tẩy) trên Broker. 
Request sẽ nằm ở cho đến khi điều kiện sao chép được thoả mãn, thay vì chặn luỗng xử lý chính của Broker. 


## 4. Control Plane: Từ Zookeeper đến Kraft (KIP-500)

Sự phát triển của Kafka đánh dấu một bước ngoặt kiến trúc lớn nhất trong lịch sử 10 ănm của nó: Loại bỏ Zookeeper để 
chuyểns ang kiến trúc tự quản lý metedata gọi là **Kraft** (Kafka Raft Metadata mode).

### 4.1. Hạn chế cốt lõi của Kiến trúc Zookeeepr
Trong kiến trúc cũ, Zookeeper đóng vai trò "bộ não" bên ngoài: Lưu trữ metadata (topic, partition, leader) và bầu chọn Controller. 
Tuy nhiên, mô hình này bộ lộ những giới hạn vật lý không thể vượt qua khi quy mô cluster tăng lên. 

Vấn đề:
* **Nút thắt cổ chai Metadata:** Controller (một Broker được bầu) phải tải toàn bộ metadata từ Zookeeper khi khởi động. Với
200,000 partitions, quá trình này có thể mất hàng chục phút, gây gián đoạn dịch vụ. 
* **Ghi đồng bộ:** Mọi thay đổi metadata phải được ghi đồng bộ vào ZK, hạn chế tốc độ thay đổi cấu hình. 
* **Split-Brain:** Có thể xảy ra tình trạng Controller nghĩ mình là Leader nhưng ZK đã bầu người khác, dẫn đến các lệnh
quản trị mâu thuẫn (Zombie Controller). 

### 4.2. Metadat như một nhật ký (The Log of ALl Logs)
KRaft loại bỏ sự phụ thuộc bên ngoài bằng cách đưa việc quản lý metadata vào chính Kafka. 
Một tập hợp các Broker được chỉ định làm **Controller Quorum.**

* **Topic** `__cluster_metadata`: Đây là trái tim của KRaft. Mọi thông tin về cluster (Broker nào đang sống, Topic nào có bao nhiêu partition...) 
không còn được lưu trong Znode của ZK nữa, mà được lưu dưới dạng các bản ghi sự kiện (event records) trong topic nội bộ này. 
* **Raft Consensus:** Các Controller sử dụng thuật toán đồng thuận Raft (một biến thể hướng sự kiện) để bầu chọn Leader
và sao chép log metadata, Leader của Metadata Log chính là Active Controller của Cluster.

### 4.3. Cơ chế truyền tải Metadata: Push vs. Pull
Sự thay đổi quan trọng nhất là cách metadata được truyền tới các Broker:
* **Cũ (Zookeeper):** Controller "Push" (đẩy) các thay đổi tới Broker qua RPC. Khi có quá nhiều thay đổi, Controller bị ngẽn mạng. 
* **Mới (Kraft):** Broker "Pull" (kéo) metadata từ Controller. Các Broker đóng vai trò như các Consumer đọc topic
`__cluster_metadata` và cập nhật trạng thái cục bộ của mình. Cơ chế này biến việc lan truyền metadata thành **Event-Driven**, 
cực kỳ hiệu quả và cho phép Kafka mở rộng tới hàng triệu Partition. 

### 4.4. Snapshotting trong KRaft

Vì `__cluster_metadata` là log append-only, nó sẽ tăng trưởng vô hạn. KRaft giải quyết bằng cơ chế **Snapshot**. Định kỳ, 
trạng thái bộ nhớ metadata được chụp lại (snapshot) và ghi xuống đĩa. Các log cũ hơn điểm snapshot có thể bị xoá. Khi khởi
động, Controller chỉ cần tải snapshot mới nhất và replay phần log đuôi, giảm thời gian phục hồi từ phút xuống giây. 

## 5. Cơ chế sao chép (Replication) và Đảm bảo dữ liệu

Độ tin cậy của Kafka dựa trên giao thức sao chép mạnh mẽ nhưng tinh tế. 
Mỗi Partition có một **Leader** và nhiều **Followers**. 

### 5.1. In-Sync Replicas (ISR)

Khái niệm quan trọng nhất của ISR. ISR là một tập hợp các bản sao đang "bắt kịp" Leader. Chỉ những bản sao trong ISR mới
đủ điều kiện để bầu làm Leader mới nếu Leader hiện tại chết. 
* **Điều kiện ISR:** Một Follower phải gửi request fetch đến Leader trong khoảng thời gian
`replica.lag.time.max.ms`. Nếu không, nó bị coi là "chết" hoặc "chậm" và bị đuổi khỏi ISR. 
* **Tính sẵn sàng vs. Độ bền:** Cấu hình `min.insync.replicas` quyết định sự đánh đổi này. Nếu số lượng 
ISR tụt xuống dưới mức này. Kafka sẽ từ chối tin nhắn mới (với `acks=all`) để bảo vệ dữ liệu, chấp nhận 
hi sinh tính sẵn sàng (availability).

### 5.2. High Watermark (HW) và Leader Epoch: Ngăn chặn mất dữ liệu và phân kỳ

Trong hệ thống phân tán, việc biết "tin nhắn nào đã an toàn" là rất phức tạp. 
* **High Watermark (HW):** Là offset của tin nhắn cuối cùng đã được sao chép thành công tới tất cả ISR. 
Consumer chỉ được đọc tới HW. Dữ liệu sau HW (gọi là vùng "uncommited") là không an toàn vì có thể mất nếu 
Leader chết. 

Tuy nhiên, chỉ dùng HW chưa đủ để xử lý các tình huống phức tạp như "Leader cũ sống lại" (Zoobie Leader). 
kafka giới thiệu Leader Epoch (kỷ nguyên lãnh đạo).
* Mỗi khi có Leader mới, số Epoch tăng lên (0, 1, 2,...)
* Mỗi tin nhắn gắn với Epoch của Leader tạo ra nó. 
* **Cơ chế Truncation:** Khi một Follower tụt hậu và kết nối lại, thay vì cắt ngắn log dựa trên HW 
(có thể không chính xác), nó trao đổi thông tin Epoch và Leader mới để xác định chính xác điểm phân kỳ 
(divergence point). Điều này ngăn chặn việt mất dữ liệu đã commit một cách oan uổng mà các phiên bản Kafka
cũ (trước 0.11) có thể gặp phải. 

## 6. Delivery Semantics: Exactly-Once (EOS)
Một trong những thành tựu lớn nhất của Kafka là hỗ trợ ngữ nghĩa "Chính xác một lần" (Exactly-Once), 
điều mà lỹ thuyết hệ thống phân tán từng coi là cực kỳ khó khăn. 

### 6.1. Idempotent Producer (Producer luỹ đẳng)
Để ngăn chặn tin nhắn bị trùng lặp do retry (khi mạng chập trờn), Kafka cho mỗi Producer một **PID**
và mỗi tin nhắn một **Sequence Number**.
* Broker lưu giữ Sequence Number cao nhất đã nhận được từ mỗi PID. 
* Nếu Producer gửi lại một tin nhắn với Sequence Number đã tồn tại (hoặc thấp hơn), 
Broker sẽ nhận biết đây là bản sao và loại bỏ nó (de-duplication) ngay tại thời điểm ghi log. 
Quá trình. này hoàn toàn trong suốt với người dùng và có chi phí hiệu năng cực thấp. 


### 6.2. Transactional API (Giao dịch Đa phân vùng)

Kafka hỗ trợ nguyên tử (atomic write) vào nhiều Partition cùng lúc thông qua giao thức **Two-Phase Commit (2PC).**

* **Transaction Coordinator:** Một module trên Broker quản lý trạng thái giao dịch. 
* **Control Messages:** Khi một giao dịch kết thúc (commit hoặc abort), Coordinator ghi một "Control Batch" (maker)
vào log của các Partition liên quan. 
* **Isolation Level:** Consumer cấu hình `isolation.level=read_committed` sẽ chỉ đọc các tin nhắn thuộc giao dịch đã 
commit và bỏ qua các tin nhắn thuộc giao dịch bị huỷ hoặc đang mở, dựa vào các maker này. 



## 7. Cơ chế Consumer và Tái cân bằng (Rebalancing)
Mô hình tiêu thủ của Kafka là **Pull-based** (kéo), cho phép Consumer kiểm soát tốc độ xử lý, tránh bị quá tải (backpressure). 


### 7.1. Offset Management: `__consumer_offsets`
Trạng thái của Consumer (đã đọc đến đâu) không được lưu trên Zookeeper (như bản cũ) mà lưu trong một topic đặc biệt `__consumer_offsets`.

* **Cấu trúc Key-Value:** Key là tổ hợp ``. Value là Offset và Metadata. 
* Topic này được Compact liên tục, chỉ giữ lại offset mới nhất, giúp việc khôi phục trạng thái cực nhanh. 


### 7.2. Các giao thức Rebalancing: Từ Eager đến Cooperative

Rebalancing xảy ra khi Consumer tham gia/rời nhóm hoặc số Partition thay đổi.
* **Eager Rebalancing (Stop-the-world):** Tất cả Consumer ngừng đọc, huỷ quyền sở hữu partition, 
và chờ phân chia lại từ đầu. Gây gián đoạn dịch vụ lớn. 

* **Incremental Cooperative Rebalancing (Kafka 2.4+):** Các Consumer không ngừng toàn bộ. 
Chúng chỉ trả lại các Partition cần phải chuyển đi cho người khác. Các Partition không bị ảnh hưởng vẫn được
xử lý bình thường. Giao thức này sử dụng nhiều vòng (phases) để đạt trạng thái cân bằng dần dần, giảm thiểu downtime 
gần như bằng không. 

## 8. Tối ưu hoá phần cứng và tích hợp hệ điều hành
Hiệu năng "khủng khiếp" của Kafka (hàng triệu tin nhắn/giây) đến từ việc thiết kế thuận theo cơ chế của phần cứng và Linux Kernal. 

### 8.1. Zero-Copy và `sendfile`
Kafka tối ưu hoá đường đi của dữ liệu từ đĩa ra mạng bằng kỹ thuật **Zero-Copy.**

* **Quy trình thường:** Disk -> Kernal Buffer -> User Buffer (Application) -> Kernal Socker Buffer -> NIC (4 lần copy, 4 context switches).
* **Kafka Zero-Copy:** Sử dụng syscall `sendfile` (Java `FileChannel.transferTo`). Dữ liệu đi từ Disk -> Page Cache -> NIC Buffer. 
  * Loại bỏ hoàn toàn việc copy dữ liệu vào bộ nhớ của JVM (User Space).
  * Giảm Context Switch.
  * Giảm áp lực lên Garbage Collector (GC) vì dữ liệu không bao giờ trở thành Java Object trong Heap. 


### 8.2. Sequential I/O và Page Cache

Kafka biến mọi thao tác ghi thành tuần tự (append-only). Trên đĩa cứng, tuần tự nhanh hơn ngẫu nhiên hàng nghìn lần (do không mất thời gian seek).
* Kafka không dùng bộ nhớ đệm riêng (Heap Cache) cho dữ liệu. Nó dùng toàn bộ RAM dư thừa của Server làm Linux Page Cache.
* Khi ghi: Ghi vào Page Cache (rất nhanh). OS sẽ flush xuống đĩa sau (background).
* Khi đọc: Nếu Consumer bắt kịp Producer, dữ liệu được đọc trực tiếp từ Page Cache (RAM hit) mà không cần chạm vào đĩa. 
* **Hệ quả:** Kafka hoạt động như một in-memory database trên nền tảng đĩa bền vững. 

### 8.3. Lựa chọn phần cứng SSD vs HDD
* **HDD:** Tốt cho thông lượng tuần tự (throughput) và chi phí lưu trữ lớn. Tuy nhiên, nếu có quá nhiều Topic/Partition, việc ghi sẽ trở thành ngẫu nhiên (random I/O) do đầu đọc phải nhảy giữa các file segment, làm giảm hiệu năng.
* **SDD/NVMe:** Khuyến nghị cho các cụm Kafka hiện đại, đặc biệt với KRaft (ghi metadata cần độ trễ thấp) và Zookeeper. SSD loại bỏ vấn đề seek time, cho phép xử lý hàng nghìn Partition mà không bị nghẽn I/O.

## 9. Tổng kết và kiến nghị

Apache Kafka không chỉ là một công cụ, mà là một hệ sinh thái được thiết kế để giải quyết bài toán dữ liệu ở quy mô lớn nhất. Việc nắm vững các khái niệm **Log, Partition, Zero-Copy, Zero-Loss (EOS)** 
và kiến trúc **KRaft** là điều kiện tiên quyết để vận hành hệ thống này hiệu quả.

**Bảng tóm tắt các đảm bảo (Guarantees)**

<table>
  <thead>
    <tr>
      <th>Thuộc tính</th>
      <th>Đảm bảo của Kafka</th>
      <th>Cơ chế thực hiện</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Thứ tự (Ordering)</td>
      <td>Chỉ trong phạm vi Partition</td>
      <td>Key-based Partitioning, Append-only Log</td>
    </tr>
    <tr>
      <td>Độ bền (Durability)</td>
      <td>Dữ liệu committed không mất (khi N−1 lỗi)</td>
      <td>Replication Factor, ISR, fsync (tùy chọn), acks=all</td>
    </tr>
    <tr>
      <td>Tính sẵn sàng (Availability)</td>
      <td>Hệ thống hoạt động khi có Leader</td>
      <td>Leader Election, Controller Quorum (KRaft)</td>
    </tr>
    <tr>
      <td>Ngữ nghĩa (Semantics)</td>
      <td>Exactly-Once (tùy chọn)</td>
      <td>Idempotent Producer (PID, SeqNum) + Transactions (2PC)</td>
    </tr>
    <tr>
      <td>Hiệu năng</td>
      <td>Thông lượng cao, độ trễ thấp</td>
      <td>Sequential I/O, Zero-Copy (sendfile), Page Cache</td>
    </tr>
  </tbody>
</table>

Báo cáo này đã cung cấp nền tảng lý thuyết vững chắc. Bước tiếp theo trong lộ trình học tập nên là thực hành cấu hình các tham số cốt lõi (`batch.size`, `linger.ms`, `acks`, `min.insync.replicas`) 
và quan sát sự thay đổi hành vi của hệ thống thông qua monitoring metrics.















