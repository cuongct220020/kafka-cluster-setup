# Apache Kafka - Kỷ nguyên Kraft và giao thức thế hệ mới

## 1. Tổng quan và phạm vi nghiên cứu

Trong bối cảnh công nghệ phân tán hiện đại, Apache Kafka đã vượt xa vai trò của một hệ thống nhắn tin (message queue) đơn thuần để trở thành xương sống của các kiến trúc Event Streaming. Báo cáo này đi sâu vào phân tích các cơ chế nội tại phức tạp nhất của Kafka, tập trung vào sự chuyển dịch kiến trúc mang tính cách mạng từ Zookeepr sang Kraft (Kafka Raft Metadata Mode), đồng thời mổ xẻ các giao thức mạng ở cấp độ nhị phân, cơ chế lưu trữ vật lý, các thuật toán đồng thuận dữ liệu. 

Mục tiêu của nghiên cứu này là cung cấp một tài liệu kỹ thuật toàn diện, giải mã "hộp đen" của Kafka nhằm phục vụ việc tối ưu hóa hệ thống cho các bài toán xử lý dữ liệu tài chính tần suất cao (High-Frequency Trading - Crypto Market Data). Phân tích được xây dựng dựa trên sự tổng hợp các tài liệu thiết kế (KIPs), mã nguồn cốt lõi và các benchmark thực tế, nhằm làm rõ mối quan hệ nhân quả giữa các quyết định thiết kế và hiệu năng hệ thống.

## 2. Kiến trúc KRaft: Cuộc cách mạng trong quản trị Metadata

Sự ra đời của KRaft (được định nghĩa qua KIP-500) không chỉ đơn giản là loại bỏ sự phụ thuộc vào Zookeeper, mà là một sự thay đổi mô hình (paradigm shift) từ quản lý trạng thái phân tán bên ngoài sang mô hình quản lý log sự kiện nội tại (Event-Sourced Metadata). Điều này giải quyết triệt để các giới hạn về khả năng partition và độ trễ phục hồi sự cố. 

### 2.1. Cơ chế đồng thuận Raft và Quorum Controller. 

Trong kiến trúc cũ, Controller là một broker duy nhất được bầu chọn thông qua Zookeeper, chịu trách nhiệm tải và quản lý toàn bộ trạng thái cluster. Khi Controller này gặp sự cố, một Controller mới phải được bầu lên và thực hiện quá trình khởi tạo (loading) trạng thái metadata từ đầu, một quy trình có độ phức tạp tuyến tính O(N) với số lượng partition, gây ra độ trễ failover đáng kể. 

Kraft thay thế mô hình này bằng một nhóm các node được gọi là **Qourum Controller**, hoạt động dựa trên thuật toán đồng thuận Raft. 

#### 2.1.1. Topic `__cluster_metadata` và Event-Sourced State

Trái tim của Kraft là một topic nội bộ đặc biệt tên là `__cluster_metadata`. Thay vì lưu trữ trạng thái hiện tại (snapshot state) như một cây thư mục trong Zookeeper, KRaft lưu trữ metadata dưới dạng một chuỗi các sự kiện (events) append-only (chỉ thêm vào).
* **Log Structure:** Mỗi thay đổi trong cluster (ví dụ: tạo topic mới, thay đổi cấu hình broker, thay đổi ISR) được mô hình hoá thành một record và ghi vào log của Active Controller. 
* **Replication:** Active Controller sử dụng giao thức Raft để sao chép (replicate) các log entry này sang các Follower Controllers. Một thay đổi chỉ được coi là "commited" khi nó đã được sao chép an toàn sang đa số (majority) các node trong quorum. 
* **State Machine Application:** Mỗi node controller (cả Active và Follower) đều chạy một State Machine trong bộ nhớ. State Machine này đọc log tuần tự và áp dụng các thay đổi để duy trì trạng thái cluster mới nhất trong RAM. Điều này đảm bảo rằng khi failover xảy ra, các Follower đã có sẵn dữ liệu nóng (hot state), cho phép chuyển đổi vai trò Leader gần như tức thời O(1). 

**Bảng 2.1: So sánh kiến trúc quản trị Zookeeper và Kraft**
<table> <thead> <tr> <th>Đặc điểm Kỹ thuật</th> <th>ZooKeeper Mode (Legacy)</th> <th>KRaft Mode (Modern)</th> </tr> </thead> <tbody> <tr> <td>Lưu trữ Metadata</td> <td>Các ZNode phân cấp trong ZooKeeper Server</td> <td>Các Record tuần tự trong Topic __cluster_metadata</td> </tr> <tr> <td>Đồng thuận (Consensus)</td> <td>ZAB (ZooKeeper Atomic Broadcast)</td> <td>Raft (Kafka Raft implementation)</td> </tr> <tr> <td>Cơ chế Lan truyền</td> <td>Push RPC: Controller đẩy metadata tới từng Broker</td> <td>Pull Fetch: Broker chủ động kéo (tailing) metadata log</td> </tr> <tr> <td>Giới hạn Scalability</td> <td>~200,000 partitions (do giới hạn ghi ZK và RPC storm)</td> <td>Hàng triệu partitions (nhờ cơ chế batching log)</td> </tr> <tr> <td>Failover Latency</td> <td>Cao (phút) - Phụ thuộc lượng metadata cần load</td> <td>Thấp (mili-giây) - State đã có sẵn trong memory</td> </tr> <tr> <td>Quản lý Security</td> <td>Cần quản lý ACLs riêng cho ZK và Kafka</td> <td>Mô hình security thống nhất trong Kafka</td> </tr> </tbody> </table>

### 2.2. Cơ chế Snapshotting và Quản lý Log Metadata (KIP-630)

Vì Metadata Log là một chuỗi vô hạn các sự kiện, kích thước của nó sẽ tăng trưởng không ngừng theo thời gian. Để ngăn chặn việc cạn kiệt dung lượng đĩa và giảm thời gian khởi động (bootstrap time) cho các node mới, KRaft giới thiệu cơ chế Snapshotting chuyên biệt, khác với Log Compaction truyền thống. 

#### 2.2.1. Kiến trúc Snapshot Độc lập

Mỗi node trong Quorum Controller thực hiện snapshot một cách độc lập dựa trên trạng thái bộ nhớ của chính nó. Một snapshot là một bản chụp toàn vẹn của State Machine tại một offset xác định (gọi là `committed offset`). 
* **Tính nhất quán:** Snapshot bao gồm `last appended index` và `term` (khái niệm trong Raft) để đảm báo tính liên tục khi nối với phần log phía sau. Điều này cho phép một node mới gia nhập chỉ cần tải snapshot mới nhất và fetch phần log delta phát sinh sau đó. 
* **Cấu trúc File Snapshot:** File snapshot bản chất một tập hợp các record metadata đã được "đóng băng". Theo KIP-630, file này được bao bọc bởi hai loại Control Record đặc biệt. 
1. **SnapshotHeaderRecord:** Luôn là batch đầu tiên, chứa thông tin version và thời điểm snapshot. 
2. **SnapshotFooterRecord:** Luôn là batch cuối cùng, đánh dấu tính toàn vẹn của file. Nếu quá trình ghi snapshort bị gián đoạn (ví dụ: mất điện), sự thiếu vắng của Footer Record sẽ báo hiệu file bị hỏng. 

#### 2.2.2. Log Cleaning và Retention

Khi một snapshot hợp lệ được tạo ra tại offset N, toàn bộ các log segment chứa các record có offset nhỏ hơn N có thể được xoá bỏ an toàn. Quá trình này giúp giới hạn dung lượng lưu trữ metadata mà không làm mất mát thông tin trạng thái.
Điều này quan trọng hơn việc dùng Log Compaction thông thường vì Metadata Log yêu cầu tính toàn vẹn tuyệt đối và thự tự áp dụng nghiêm ngặt, việc compact "lỏng lẻo" có thể gây ra sai lệnh trạng thái. 

### 2.3. Dynamic Qourum Reconfiguration (KIP-853)

Một trong những hạn chế lớn của một hệ thống Raft tĩnh là khó kăhnt rong việc thay đổi thành viên của nhóm đồng thuận (Voter Set) khi đang vận hành. KIP-853 mang đến khả năng tái cấu hình hành động cho KRaft. 
* **Voter Set trong Metadata:** Danh sách các node có quyền bầu cử (voters) được lưu trữ chính bên trong Metadata Log. 
* **Cơ chế Add/Remove:** Khi quản trị viên muốn thêm một controller mới, một record thay đổi cấu hình gửi tới Active Controller. Controller này sẽ append record đó vào log. Sự thay đổi cấu hình có hiệu lực ngay khi record đó được commit. 
* **Ứng dụng thực tế:** Cho phép thay thế các controller bị lỗi phần cứng mà không cần tắt cluster, hoặc mở rộng quorum từ 3 node lên 5 node để tăng khả năng chịu lỗi (fault tolerance) khi quy mô hệ thống lớn lên. 

## 3. Cơ chế lưu trữ vật lý và tối ưu hoá I/O

Hiệu năng vượt trội của Kafka trong việc xử lý thông lượng (throughput) lớn xuất phát từ triết lý thiết kế "Disk-based but Memory speed". Kafka tận dụng tối đã cơ chế của hệ điều hành hiện đại thay vì cố gắng tái tạo lại việc quản lý bộ nhớ trong tầng ứng dụng. 

### 3.1. Cấu trúc Log Segment: Giải phẫu chi tiết

Mỗi partition trong Kafka thực chất là một thư mục trên đĩa, chứa một chuỗi các file được gọi là **Log Segments**. Việc chia nhỏ log thành các segment giúp việc quản lý vòng đời dữ liệu (retention, compaction) trở nên khả thi. 

#### 3.1.1. File `.log`: Dữ liệu tuần tự
* File này chứa các message thực sự, được lưu trữ dưới dạng binary wire format. Điều này có ý nghĩa quan trọng: dữ liệu trên đãi có định dạng y hệt dữ liệu truyền qua mạng.
* Kafka sử dụng chiến lược append-only. Mọi dữ liệu mới luôn được ghi vào cuối file segment hiện hành (active segment). Việc ghi tuần tự (sequential write) trên đĩa cứng (HDD) hoặc SDD nhanh hơn rất nhiều so với ghi nhẫu nhiên (random write), đạt tốc độ gần tương đương với ghi vào bộ nhớ. 


#### 3.1.2. Hệ thống Indexing kép (Dual Indexing Architecture)
Để hỗ trợ việc đọc dữ liệu tại bất kỳ vị trí nào mà không cần quyét toàn bộ file log khổng lồ, Kafka duy trì hai loại index song song. Điểm đặc biệt là cả hai đều là **Sparse Index** (Index thưa), nghĩa là kafka không lưu index cho mọi message, mà chỉ lưu định kỳ sau một khoảng byte nhất định (`log.index.interval.bytes`, mặc định 4KB). 

**Bảng 3.1: Chi tiết cấu trúc các File Index**


_Phân tích sâu:_ Việc sử dụng Sparse Index là một sự đánh đổi (trade-off) tinh tế. Nó giảm kích thước file index xuống hàng nghìn lần so với B-Tree Index của database thông thường, cho phép toàn bộ index có thể được load và giữ trong RAM (OS Page Cache). 
Chi phí phải trả là việc phải quyét (scan) một khoảng nhỏ dữ liệu thô (tối đa 4KB) khi đọc, nhưng với tốc độ đọc tuần tự của đĩa, độ trễ này là không đáng kể.

## 3.2. Cơ chế Log Compaction: Key-Value Stream
Log Compaction là cơ chế biến Kafka từ một event log tạm thời thành một kho lưu trữ trạng thái vĩnh viễn (giống database). Nó đảm bảo rằng hệ thống luôn giữ lại ít nhất bản ghi cuối cùng cho mỗi Message Key. 

### 3.2.1. Kiến trúc Head và Tail
Log của một partition được chia thành hai vùng logic: 
* **Tail (Đã làm sạch):** Phần log cũ, nơi các record đã được compact. Tại đây, mỗi key là duy nhất. 
* **Head (Chưa làm sạch):** Phần log mới, chúa các ghi chép tuần tự chưa được xử lý. 

### 3.2.2. Thuật toán Cleaner Thread
Các luồng dọn dẹp (Cleaner Threads) chạy ngầm và thực hiện quy trình sau: 
1. **Lựa chọn:** Chọn Log có `Dirty Ratio` cao nhất (tỷ lệ dữ liệu chưa clean so với tổng dữ liệu). 
2. **Xây dựng Map:** Đọc phần Head của log và xây dựng một **OffsetMap** trong bộ nhớ (Hash Map mapping từ `Key` sang `Last Offset`). 
Map này chỉ cần lưu 16 byte cho mỗi entry (hashed key + offset) để tiết kiệm RAM. 
3. **Lọc và Sao chép:** Đọc tuần tự từ đầu log (cả Tail và Head). Với mỗi record, kiểm tra xem offset của nó có bằng với offset trong Map hay không. 
* Nếu bằng: Đây là phiên bản mới nhất, giữ lại. 
* Nếu nhỏ hơn: Đã có phiên bản mới hơn trong phần sau của log, loại bỏ (delete). 
4. **Atomic Swap:** Ghi kết quả ra file `.swap` và đổi tên thành `.log` mới một cách nguyên tử. 

## 3.3. Zero-Copy và tối ưu hoá Page Cache

Đây là "vũ khí bí mật" giúp Kafka đạt throughput cao mà JVM Heap không bị quá tải. 

### 3.3.1. Page Cache Centric Design
Kafka không cố gắng quản lý bộ nhớ đệm trong không gian người dùng (User Space). Thay vào đó, nó chuyển qua hoàn toàn việc này cho Kernel thông qua **Page Cache**. 
* Khi Kafka ghi dữ liệu: Dữ liệu được đẩy xuống OS Cache. OS sẽ quyết định khi nào flush xuống đĩa (write-back). 
* Khi Kafka đọc dữ liệu: OS sẽ phục vụ trực tiếp từ RAM nếu dữ liệu còn nóng (hot). 
* Lợi ích: Khi JVM khởi động lại, Page Cache của OS vẫn còn nguyên, giúp node phục hồi trạng thái "nóng" ngay lập tức, không cần warm-up cache lại từ đầu.

### 3.3.2. Zero-Copy Data Transfer

Trong luồng truyền dữ liệu truyền thống (File $\rightarrow$ Socket), dữ liệu phải đi qua 4 lần copy và 4 lần context switch (Disk $\rightarrow$ Kerner Buf $\rightarrow$ User Buf $\rightarrow$ Kernel Socket Buf $\rightarrow$ NIC). Kafka sử dụng system call `sendfile` (thông qua Java `FileChannel.transferTo`), cho phép dữ liệu đi trực tiếp từ **Page Cache $\rightarrow$ Network Interface Card (NIC)** thông qua DMA (Direct Memory Access), bỏ qua hoàn toàn việc copy vào bộ nhớ của ứng dụng (User Space). Kết quả: Giảm CPU usage tới 60%, giảm context switch, và tận dụng tối đa băng thông mạng. 

## 4. Giao thức mạng và mô hình xử lý Request

Kafka định nghĩa một giao thức nhị phân (binary protocol) riêng trên nền TCP mới, được tối ưu hoá cho việc xử lý theo lỗ (batching) và tương thích ngược (backward compability). 

### 4.1. Kiến trúc Threading Model: Refactor Pattern
Broker xử lý hàng nghìn kết nối đồng thời bằng mô hình Reactor bất đồng bộ, phân tách rõ ràng giữa xử lý kết nối (nhẹ) và xử lý đĩa (nặng).

1. **Acceptor Thread (1 thread):** Lắng nghe port 9092, chấp nhận kết nối TCP mới và gán (round-robin) cho các Processor Thread.
2. **Processor Threads (Network Threads):** Số lượng cấu hình qua `num.network.threads`. Mỗi Thread quản lý nhiều kết nối socket thông qua Java NIO Selector (epoll trên Linux).
* Nhiệm vụ: Đọc toàn bộ byte từ socket, phân rã thành Request Object, đẩy vào `RequestQueue`. 
* Nhiệm vụ ngược lại. Lấy Response từ `ResponseQueue`, ghi Byte xuống socket trả client. 
3. **Request Handler Threads (IO Theads):** Số lượng cấu hình qua `num.io.threads`.
* Nhiệm vụ: Lấy Request từ hàng đợi, thực hiện logic nghiệm vụ (ghi log, đọc log, replicate), tạo response, đẩy vào `ResponseQueue`. 

Mô hình này đảm bảo rằng các luồng mạng không bao giờ bị block bởi các thao tác I/O đĩa chậm chạp. 

### 4.2. Request Purgatory: Quản lý Delayed Operations

Không phải request nào cũng có thể hoàn thành ngay. Ví dụ `ProduceRequest` với `acks=all` phải đợi replication, hoặc `FetchRequest` phải đợi đủ dữ liệu (`min.bytes`). Kafka không block thread xử lý mà đẩy các request này vào vùng chờ gọi là `Purgatory`.

#### 4.2.1. Hierarchical Timing Wheels (Bánh xe thời gian phân cấp)

Để quản lý hàng chục nghìn request đang chờ timeout một cách hiệu quả, Kafka sử dụng cấu trúc dữ liệu `Hierarchical Timing Wheels`. 
* Cấu trúc này cho phép các thao tác thêm (insert) và huỷ (cancel) timer với độ phức tạp O(1), tốt hơn nhiều so với O(logN) của `java.util.concurrent.DelayQueue` (dùng PriorityHeap).
* **Watchers:** Mỗi request trong Purgatory được gắn với một danh sách các khoá (watch keys). Ví dụ: `ProduceRequest` sẽ watch trên partition mà nó ghi vào. Khi một sự kiện xảy ra (ví dụ: HW tăng lên), Watcher sẽ được kích hoạt để kiểm tra xem request đã thoả mãn điều kiện chưa để complete sớm, không cần đợi hết timeout. 

## 5. Replication Protocol và Data Consistency

Cơ chế sao chép (replication) của Kafka là nền tảng của độ bền dữ liệu. Tuy nhiên, các khái niệm nội tại như ISR, High Watermark và Leader Epoch thường chứa đựng nhiều chi tiết tinh vi dễ gây hiểu lầm.

### 5.1. Cơ chế ISR (In-Sync Replicas) và High Watermark
* **Log End Offset (LEO):** Offset của message cuối cùng được ghi vào log của một replica. 
* **High Watermark (HW):** Offset của message cuối cùng được coi là đã commit. HW được tính là giá trị LEO nhỏ nhất trong tập hợp ISR. Quan trọng: Consumer chỉ được phép đọc tới HW để đảm báo tính nhất quán (Read Committed).
* **ISR Dynamics:** Một follower được coi là In-Sync nếu nó gửi Fetch Request tới Leader trong khoảng thời gian `replica.lag.time.max.ms`. Nếu follower bị chậm hoặc chết, nó bị đã khỏi ISR. Khi đó, HW có thể tăng lên (do tập ISR nhỏ đi, điều kiện commit dễ hơn), giúp Producer không bị block.

### 5.2. Vấn đề Truncation và Giải pháp Leader Epoch (KIP-101)
Trong các phiên bản cũ, Kafka chỉ dựa vào HW để giải quyết việc cắt ngắn (truncate) log khi follower rejoin. Điều này dẫn đến hai lỗ hổng nghiêm trọng: 
1. **Mất dữ liệu:** Nếu Leader crash ngay sau khi ghi message nhưng chưa kịp tăng HW, Follower lên thay có thể ghi đè dữ liệu đó. 
2. **Log Divergence:** Các replica có thể có nội dung khác nhau tại cùng một offset. 

**Leader Epoch** giải quyết vấn đề này bằng cách gán các phiên bản (epoch) cho mỗi khoảng thời gian một broker làm Leader.
* Mỗi khi có Leader mới, Epoch tăng lên. Mỗi message được gắn kèm (`Leader Epoch`, `Start Offset`). 
* **Giao thức mới:** Khi Follower kết nối lại, thay vì truncate bừa bãi theo HW, nó gửi `OffsetsForLeaderEpochRequest` hỏi Leader hiện tại: "Với Epoch X của tôi, offset kết thúc hợp lệ là bao nhiêu?". Leader tra cứu trong `LeaderEpochCheckpoint` file và trả về điểm cắt chính xác. Điều này đảm bảo tính toàn vẹn dữ liệu tuyệt đối ngay cả trong các tình huống failover phức tạp nhất. 

### 5.3. Idempotent và Tracsactional Producer: Exactly-Once Semantics (EOS)

Kafka hỗ trợ ngữ nghĩa "chính xác một lần" thông qua cải tiến sâu trong Protocol.

#### 5.3.1. Idempotent Producer (`enable.idempotence=true`)
* **PID & Sequence Number:** Mỗi Producer được gán một một ID (PID). Mỗi batch message gửi đi có một số thứ tự (Sequence Number) tăng dần 0, 1, 2...
* **Broker De-duplication:** Broker lưu trữ Sequence Number cuối cùng nhận được từ mỗi PID. nếu nhận được SeqNum thấp hơn bằng cái đã lưu (do Producer retry khi mạng lag), Broker sẽ loại bỏ bản tin trùng lặp nhưng vẫn trả về ACK cho Producer. 

#### 5.3.2. Transactional Producer (Atomic Writes)

Cho phép ghi nhiều partitions/topic nguyên tử (all-or-nothing).
* **Two-Phase Commit (2PC):** Kafka hiện thực hoá 2PC ngay trong log. 
1. User bắt đầu transaction.
2. Producer gửi data tới các topic user. 
3. User commit tracsaction. 
4. Transaction Coordinator (trên broker) ghi `PrepareCommit` vào `__transaction_state`. 
5. Coordinator ghi **Control Batch (Commit Maker)** vào log của các topic user. Maker này vô hình với consumer thường. 
6. Consumer với `isolation.level=read_committed` sẽ chỉ trả về message khi đã nhìn thấy Commit Maker tương ứng.

## 6. Consumer Group Protocol: Thế hệ mới (KIP-848)

Phiên bản Kafka 4.0 (và thử nghiệm trong 3.7+) giới thiệu giao thức Consumer Group hoàn toàn mới để giải quyết vấn đề muôn thuở: "Stop-the-world Rebalance".

### 6.1. Hạn chế của giao thức cổ điển

Trong giao thức cũ, khi một consumer mới tham gia hoặc consumer cũ rời đi, **toàn bộ** nhóm phải dừng consume, huỷ bỏ quyền sở hữu mọi partition, và chờ đợi quá trình phân chia lại (rebalance) hoàn tất. Trong các cluster lớn, quá trình này gây ra "bão" rebalance, làm hệ thống tê liệt trong vài chục giây đến vài phút. 

### 6.2. Next Generation Protocol (KIP-848)

Giao thức mới chuyển phần lớn logic phức tạp từ phía Client (Consumer Lib) về phía Server (Group Coordinator). 
* **Incremental Rebalance:** Thay vì thu hồi tất car partition, Coordinator tính toán sự thay đổi tối thiểu và chỉ yêu cầu consumer trả lại các partition cần thiết chuyển đi. Các partition không bị ảnh hưởng vẫn được consume bình thường. 
* **Heartbeat-driven Assignment:** Thông tin về phân chia partition được nhúng trực tiếp vào các hearbeat response. Consumer không cần gửi `JoinGroup` / `SyncGroup` request riêng biệt, giúp giảm traffic RPC và tăng tốc độ hội tụ trạng thái. 
* **Tác động:** Giảm độ trễ rebalance từ quy mô phút xuống mili-giây, cho phép Consumer Group ổn định hơn rất nhiều trong môi trường dynamic (như Kubernetes với các pod thường xuyên restart). 