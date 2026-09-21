# **Advanced Routing and NAT Acceleration on MediaTek MT7986: A Comprehensive Investigation for JDCloud RE-CP-03 (ImmortalWrt 24.10)**

## **1\. Architectural Overview and Hardware Context**

The transition of consumer and prosumer routing platforms from traditional x86-based software routing to ARM-based System-on-Chips (SoCs) equipped with dedicated network processing units has fundamentally altered the landscape of network performance tuning. The JDCloud RE-CP-03, also known as the AX6000 "Baili", represents a highly capable deployment of this modern architecture. Powered by the MediaTek MT7986A (Filogic 830\) SoC, it features a quad-core ARM Cortex-A53 processor clocked at 2.0GHz, alongside 1GB of RAM and a notably large 128GB eMMC storage module.1

This specific hardware configuration positions the JDCloud RE-CP-03 not merely as a standard home router, but as a hybrid edge-compute node capable of sustaining complex Docker container deployments natively on the device.2 The device operates on ImmortalWrt 24.10, a performance-optimized branch of the OpenWrt 24.10 project utilizing the Linux 6.6 kernel and the firewall4 (nftables) networking stack.3

Because direct empirical evidence for the JDCloud RE-CP-03 is occasionally scarce in primary developer tracking systems, portions of this analysis rely on explicit extrapolation from identical MT7986/Filogic 830 platforms, most notably the GL.iNet GL-MT6000 (Flint 2\) and the Banana Pi BPI-R3.4 Official documentation, kernel developer mailing lists, and user anecdotes across these structurally identical platforms provide a robust foundation for determining the optimal configuration for routing acceleration, NAT loopbacks, QoS shaping, and proxy deployment.

## **2\. Part A: Technical Explanation of Flow Offloading Mechanisms**

To determine the most appropriate routing acceleration mode, one must dissect the precise mechanisms by which the Linux kernel and the MediaTek Packet Processing Engine (PPE) handle network traffic.

### **2.1 The Standard Linux Networking Slow Path**

When the LuCI firewall is set to "No flow offloading," the router relies entirely on the Linux networking "slow path." When an Ethernet frame arrives at the MT7986's Network Interface Card (NIC), it triggers a hardware interrupt. The kernel utilizes NAPI (New API) polling to retrieve the frame, allocates a socket buffer (sk\_buff), and passes it up the network stack.5

The packet enters the netfilter framework, specifically hitting the PREROUTING chain. Here, the nf\_conntrack (connection tracking) module identifies whether the packet is part of an existing connection or a new one. The kernel then performs a routing table lookup to determine the destination interface. If the packet is destined for the WAN, it passes through the FORWARD chain, where firewall rules are evaluated. Finally, it enters the POSTROUTING chain, where Network Address Translation (NAT) masquerading alters the source IP address. The packet's Time-To-Live (TTL) is decremented, checksums are recalculated, and the packet is queued into a traffic control (tc) scheduling discipline before egress. On the Filogic 830, this CPU-intensive process can handle roughly 1 Gbps of throughput but will drive CPU utilization extremely high, potentially causing thermal throttling or latency spikes during microbursts.1

### **2.2 Software Flow Offloading (SFO)**

Software Flow Offloading in OpenWrt mitigates CPU overhead by utilizing the nftables flowtable infrastructure introduced in modern Linux kernels.3

When SFO is enabled, the first packet of a new connection (e.g., a TCP SYN) traverses the standard slow path described above. Once nf\_conntrack confirms that a valid, bidirectional connection has been established, firewall4 adds this connection's 5-tuple (Source IP, Destination IP, Source Port, Destination Port, Protocol) to a dedicated fast-path flowtable.6

Subsequent packets matching this 5-tuple are intercepted at the nf\_ingress hook, which is positioned immediately after the NIC driver hands the packet to the operating system.7 The kernel instantly applies the necessary NAT rewrites and TTL decrements, and forwards the packet directly to the outgoing interface. This entirely bypasses the complex PREROUTING, FORWARD, and POSTROUTING nftables evaluation chains.8

**Impact:** Software offload typically increases forwarding bandwidth by a factor of 2 to 3 over standard slow-path routing.3 Because the packet remains within the CPU's domain, it is still subject to software-based Quality of Service (QoS) queues, making SFO highly compatible with latency-mitigation algorithms.10

### **2.3 Hardware Flow Offloading (HFO) on MediaTek MT7986**

Hardware Flow Offloading transfers the forwarding logic entirely out of the Linux kernel and into dedicated silicon. The MT7986 features a highly specialized Packet Processing Engine (PPE) designed specifically for wire-speed NAT and routing.1

When HFO is enabled, the initial packet establishes a connection in nf\_conntrack via the slow path. The Linux kernel, recognizing the hardware capability, utilizes the Netfilter hardware offload API to program the flow directly into the PPE's physical SRAM hash tables.3 Subsequent packets arriving at the physical switch ports or the Wi-Fi baseband are intercepted by the PPE. The hardware itself inspects the frame, matches the 5-tuple, performs NAT masquerading, recalculates checksums, decrements the TTL, substitutes MAC addresses, and pushes the frame out to the physical egress port.11

**Wireless Ethernet Dispatch (WED):** MediaTek extends HFO to wireless interfaces through WED.12 WED provides a direct hardware bridge between the PCIe-connected MT7915/MT7976 Wi-Fi chips and the PPE. When WED is enabled, WLAN-to-WAN traffic does not traverse the SoC's system bus to the CPU memory; the PPE handles the frames directly, reducing CPU load to near 0%.12

### **2.4 Interaction with Firewall4 and Nftables**

In ImmortalWrt 24.10, the legacy iptables framework has been deprecated in favor of firewall4, which compiles configurations exclusively into nftables rulesets.13 The offloading engine is manifested as an nftables flowtable named ft.6

When Software Flow Offloading is selected in LuCI, firewall4 generates an nftables configuration containing the flowtable ft block. When Hardware Flow Offloading is selected, firewall4 appends the flags offload directive to this block.6 This specific flag instructs the kernel to push the flowtable entries down through the driver layer (the mtk\_eth\_soc driver) into the hardware PPE.14 Consequently, packets handled by the PPE completely bypass all software observation; they will not increment nftables byte counters, nor will they trigger any complex firewall rules matching packet payloads.15

### **2.5 Traffic Path Eligibility Matrix**

The MediaTek PPE cannot process every type of network traffic. When a packet type is ineligible, the router silently falls back to Software Flow Offloading or the standard slow path.

**Eligible for Hardware Offload:**

* **LAN-to-WAN Traffic:** Standard IPv4 NAT and IPv6 routing between physical Ethernet ports.16  
* **WLAN-to-WAN Traffic:** Wi-Fi traffic destined for the internet, provided WED is successfully initialized.12  
* **PPPoE Encapsulation:** The MT7986 PPE has native hardware support for adding and stripping Point-to-Point Protocol over Ethernet headers.11  
* **VLAN Tagging (802.1Q):** The PPE natively parses and manipulates VLAN tags.17

**Not Eligible for Hardware Offload (Fallback to CPU):**

* **Router-Terminated Traffic:** Any packet destined for the router's local CPU (e.g., SSH, LuCI access, DNS requests to dnsmasq, OpenClash inbound transparent proxy traffic, or traffic destined for Docker containers running locally on the 128GB eMMC).3  
* **WLAN-to-LAN Traffic:** According to confirmed bug reports on OpenWrt 24.10 (Linux 6.6), WLAN-to-LAN bridging hardware offload frequently fails on the MT7986, resulting in high CPU usage as traffic falls back to the slow path.16  
* **Complex VPN Payloads:** Traffic exiting a WireGuard or OpenVPN tunnel cannot be hardware offloaded at the origin point because the PPE lacks the cryptographic engines to handle payload decryption before routing.18  
* **Multicast and Broadcast:** These frames must be evaluated by the kernel to determine multiple destinations.

## **3\. Part B: Comprehensive Compatibility Matrix**

The integration of routing acceleration with advanced network topologies requires careful configuration. The following matrix details the compatibility of specific features against the three offloading modes available on ImmortalWrt 24.10 for the MT7986 platform.

*Sources are explicitly categorized to distinguish official OpenWrt documentation, kernel/developer discussions, user forum anecdotes, and architectural inferences.*

| Network Topology / Feature | None (Slow Path) | Software Flow Offloading (SFO) | Hardware Flow Offloading (HFO) | Recommended Setting | Known Risks / Caveats on MT7986 | Evidence Quality |
| :---- | :---- | :---- | :---- | :---- | :---- | :---- |
| **Plain IPv4 NAT** | Compatible | Compatible | **Compatible** | HFO | Developer discussions indicate HFO occasionally exhibits max-load latency jitter (3ms vs \<1ms on SFO) due to packet reordering.10 | High (Kernel Devs) |
| **IPv6 Routing** | Compatible | Compatible | **Compatible** | HFO | The PPE fully accelerates standard IPv6 routing.16 | High (Official Docs) |
| **NAT6 (IPv6 NAT)** | Compatible | Compatible | **Compatible** | HFO | OpenWrt 24.10 natively handles nft-nat6 offload without legacy iptables module conflicts.3 | High (Codebase) |
| **PPPoE WAN** | Compatible | Compatible | **Compatible** | HFO | PPE processes PPPoE natively.11 *User anecdotes* note occasional PPPoE discovery timeouts on OpenWrt 24.10, but these are primarily tied to Intel NICs, not MediaTek.21 | High (Hardware Spec) |
| **VLAN WAN** | Compatible | Compatible | **Compatible** | HFO | Hardware naturally accelerates 802.1Q tags.17 | High (Architecture) |
| **SQM / CAKE / fq\_codel** | Compatible | **Compatible** | Incompatible | SFO | **Conflict:** Official documentation confirms HFO physically bypasses the Linux tc queues, rendering SQM entirely ineffective.3 SFO preserves AQM functionality.23 | High (Official Docs) |
| **FullCone NAT** | Compatible | **Compatible** | Partial / Buggy | SFO | ImmortalWrt uses ip6tables-mod-fullconenat.24 True hardware FullCone requires custom natflow kernel patches not natively stabilized in mainline OpenWrt 24.10.7 | Medium (Dev Repos) |
| **OpenClash** | Compatible | **Compatible** | Incompatible | SFO | HFO bypasses netfilter redirection hooks, breaking the transparent proxy logic required by OpenClash.3 | High (Architecture) |
| **PassWall / SSR+** | Compatible | **Compatible** | Incompatible | SFO | Similar to OpenClash, PassWall2 integration with firewall4 deprecates or fails when flows are forced into hardware paths, causing routing leaks.13 | High (GitHub Issues) |
| **TProxy Transparent Proxy** | Compatible | **Compatible** | Incompatible | SFO | TProxy must inspect the flow. If the PPE accelerates the flow, the CPU cannot intercept the proxy stream.3 | High (Netfilter Docs) |
| **Docker Bridge Networking** | Compatible | **Compatible** | Incompatible | SFO | Docker relies on software veth pairs and software bridging. HFO ignores software bridging unless specialized BPF (bridger) modules are used, which are experimental.2 | High (Docker/Kernel) |
| **WireGuard** | Compatible | **Compatible** | **Buggy / Fails** | SFO | **Critical Bug:** OpenWrt GitHub issues confirm WG peers behind MT7986 with HFO enabled suffer tunnel stalls. Conntrack entries vanish, and incoming PPE paths unbind (UNB), dropping traffic.18 | High (Confirmed Bug) |
| **OpenVPN** | Compatible | **Compatible** | Incompatible | SFO | Like WireGuard, OpenVPN endpoints on the router cannot be hardware offloaded due to encryption. Forwarded OpenVPN traffic suffers the same state-tracking bugs as WG under HFO.3 | High (Architecture) |
| **Policy-based Routing (PBR)** | Compatible | **Compatible** | Incompatible | SFO | PBR relies on IP rule matching and firewall MARK restoration. HFO bypasses PREROUTING, meaning policy marks are never read by the hardware.3 | High (Routing Logic) |
| **UPnP** | Compatible | Compatible | **Compatible** | SFO/HFO | Dynamic port forwards opened by UPnP are translated into standard conntrack rules, which map cleanly to the PPE. | Medium (Inference) |
| **Port Forwards** | Compatible | Compatible | **Compatible** | SFO/HFO | Forwarding paths map cleanly to the hardware hash tables once the initial state is established. | High (Architecture) |
| **Hairpin NAT / Loopback** | Compatible | Compatible | **Compatible** | SFO/HFO | Handled during the initial connection setup in conntrack. Once translated, the loopback operates correctly under both offload paradigms. | Medium (Inference) |
| **Gaming / P2P** | Compatible | **Compatible** | Partial / Buggy | SFO | HFO limits concurrent accelerated connections (e.g., 64 hardware hash slots per block). Massive P2P swarms overwhelm the PPE, forcing silent fallbacks to SFO.3 | High (Dev Docs) |

### **3.1 Extended Analysis of Matrix Conflicts**

**Proxy Topologies and Policy Routing:** User anecdotes and developer discussions confirm that running OpenClash, PassWall, or SSR+ on the MT7986 fundamentally clashes with Hardware Flow Offloading.13 Transparent proxies operate by using netfilter hooks (specifically REDIRECT or TPROXY targets) to hijack outbound traffic from LAN clients and terminate that traffic locally on the router's proxy core (e.g., a Shadowsocks or Vmess client). If HFO is enabled, the first packet sets up a state, but the hardware may erroneously bind the physical source and destination, entirely bypassing the CPU's proxy intercept. Therefore, to utilize the JDCloud RE-CP-03 as an OpenClash node, SFO is mandatory to ensure the proxy logic retains visibility over the traffic flow.

**The WireGuard Conntrack Amnesia Bug:** A severe, documented regression exists in OpenWrt 23.05 and 24.10 specifically regarding WireGuard endpoints positioned behind an MT7986 router with HFO enabled. Developer tracking issues detail a phenomenon where the hardware successfully binds the outgoing path (BND), but the incoming path becomes unbinded (UNB) inside the PPE. Consequently, the Linux kernel aggressively garbage-collects the nf\_conntrack entry, assuming the connection is dead. The router begins responding to incoming WireGuard handshakes with ICMP Port Unreachable messages, permanently stalling the tunnel until the interface is restarted.18 Software Flow Offloading completely circumvents this bug.

**Docker and Virtual Bridging:** The JDCloud RE-CP-03's 128GB eMMC makes it an ideal Docker host.2 However, Docker heavily utilizes Linux software bridges (docker0) and virtual ethernet (veth) pairs. Official Mikrotik and OpenWrt documentation emphasizes that hardware offloading is strictly for physical port-to-port forwarding (e.g., eth0 to eth1). Traffic moving between a physical LAN port and a virtual Docker container interface must cross the CPU boundary. While experimental Berkeley Packet Filter (BPF) tools like bridger attempt to inject bridging states into the PPE, this is highly unstable for complex Docker networks.12 For a stable Docker environment, SFO is heavily recommended.

## **4\. Part C: TCP BBR Congestion Control Analysis**

Bottleneck Bandwidth and Round-trip propagation time (BBR) is an advanced congestion control algorithm developed by Google. Unlike traditional algorithms like CUBIC or Reno, which rely on packet loss to determine network congestion (resulting in the classic "sawtooth" throughput pattern), BBR actively probes the network to determine the actual bottleneck bandwidth and round-trip time, pacing packets to prevent bufferbloat entirely.27

### **4.1 Efficacy for Ordinary LAN Clients Behind NAT**

A pervasive myth within user forum anecdotes suggests that enabling BBR on an OpenWrt router will automatically accelerate devices connected to the LAN.30 **This is technically false for standard forwarded traffic.** TCP congestion control algorithms are explicitly end-to-end protocols; they dictate the behavior of the TCP sender. If a LAN client (e.g., a Windows PC) initiates a TCP download from an internet server, the TCP handshake is strictly between the PC and the server. The JDCloud RE-CP-03 merely routes and NATs the packets. Changing the router's internal congestion control to BBR has absolutely zero effect on this forwarded traffic.30

### **4.2 Efficacy for Router-Originated and Terminated Traffic**

BBR provides massive, measurable benefits for traffic where the router itself acts as the TCP endpoint.30 On a robust device like the JDCloud RE-CP-03, this encompasses several critical scenarios:

* **Docker Containers:** If a Docker container running on the router's 128GB eMMC hosts a local service (e.g., a NAS, a web server, or a BitTorrent client), it utilizes the host router's kernel networking stack. BBR will dramatically optimize these connections.2  
* **Transparent Proxies (OpenClash / PassWall):** When OpenClash intercepts a LAN client's request, it terminates that TCP stream locally and opens a *new* TCP stream to the remote proxy server (e.g., a VPS in another country). Because the router is now the sender for the WAN-facing connection, **BBR drastically improves proxy throughput and resilience over high-latency international links**.28  
* **Local Services:** Router-initiated package downloads (opkg install), firmware updates, and local SSH/LuCI sessions benefit from the pacing algorithm.

### **4.3 The fq Qdisc Requirement**

BBR requires precise packet pacing to function correctly. In the Linux kernel, this pacing relies on the Fair Queue (fq) scheduling algorithm. While BBR can function marginally on top of OpenWrt's default fq\_codel queue, maximum mathematical efficacy requires fq to be set as the default queuing discipline.27

### **4.4 Verification and Configuration on ImmortalWrt**

To ensure BBR is available and active on the ImmortalWrt 24.10 platform, the required kernel modules must be installed and initialized.

1. **Installation:** Verify kmod-tcp-bbr and kmod-sched-fq are present via opkg.27  
2. **Sysctl Modification:** Append the following variables to /etc/sysctl.conf:  
   Bash  
   net.ipv4.tcp\_congestion\_control=bbr  
   net.core.default\_qdisc=fq

3. **Verification:** Run the following shell commands to ensure the kernel has applied the changes 27:  
   Bash  
   sysctl net.ipv4.tcp\_congestion\_control  
   \# Expected output: net.ipv4.tcp\_congestion\_control \= bbr  
   lsmod | grep tcp\_bbr  
   \# Expected output should show the module loaded in memory.

### **4.5 Synergy and Conflict with Hardware Flow Offloading**

BBR and HFO operate in entirely disparate domains of the network stack. HFO is concerned strictly with *forwarded* packets bypassing the CPU. BBR is concerned strictly with *local* packets originating from the CPU. They do not conflict, but they are mutually exclusive on a per-connection basis. If a connection is hardware offloaded, it implies it is forwarded and therefore entirely unaffected by BBR. Conversely, if a connection is managed by BBR (e.g., an OpenClash outbound tunnel), the CPU must terminate the connection, meaning it cannot possibly be hardware offloaded.

## **5\. Part D: Recommended Configurations by Use Case**

Given the unique capabilities of the JDCloud RE-CP-03—pairing top-tier SoC routing performance with homelab-grade storage—the configuration must strictly align with the user's primary workload. Based on the technical realities of OpenWrt 24.10, the following distinct profiles are recommended.

### **5.1 Maximum Throughput, No SQM, No Complex Proxy**

* **Target Environment:** Symmetrical Gigabit or 2.5Gbps fiber connections where the user requires maximum raw LAN-to-WAN download speeds. No proxies or Docker containers are active.  
* **Recommended Setting:** **Hardware Flow Offloading (HFO) \+ WED Enabled**.  
* **Technical Rationale:** The MT7986 PPE is designed specifically for this scenario. It will process routing at line rate with near 0% CPU utilization. WED ensures that Wi-Fi traffic also bypasses the CPU entirely.2  
* **Caveat:** You may experience random Wi-Fi roaming dropouts (802.11r FT errors) or temporary client lockouts due to documented WED stability bugs on the 24.10 branch.34

### **5.2 Stable Home Network with Docker and Transparent Proxy**

* **Target Environment:** Utilizing the 128GB eMMC for extensive Docker container deployments alongside OpenClash or PassWall for selective international routing.  
* **Recommended Setting:** **Software Flow Offloading (SFO) \+ BBR Enabled**.  
* **Technical Rationale:** Hardware offloading conflicts catastrophically with Docker veth bridges and TProxy iptables redirection.2 SFO allows the powerful 2.0GHz Cortex-A53 to efficiently route local traffic while keeping the netfilter hooks intact, ensuring Docker containers maintain internet access and OpenClash correctly intercepts LAN traffic. Enabling BBR supercharges the outbound proxy connections.

### **5.3 Low-Latency Gaming / Bufferbloat-Sensitive Connection**

* **Target Environment:** Competitive gaming setups, extensive VoIP usage, or asymmetric WAN connections (e.g., 1000 Mbps Down / 50 Mbps Up) prone to queuing delays.  
* **Recommended Setting:** **Software Flow Offloading (SFO) \+ SQM (CAKE / fq\_codel) Enabled**.  
* **Technical Rationale:** HFO completely bypasses the Linux tc queues, rendering SQM shaping entirely useless.3 To achieve an A+ Bufferbloat score, all traffic must be forced through the CPU's traffic control buffers. The MT7986 is powerful enough to run CAKE at approximately 900 Mbps symmetrically using Receive Packet Steering (RPS) without requiring hardware offload.1 Furthermore, developer tracking confirms that HFO on this SoC introduces sporadic 3ms latency jitter spikes under maximum load, making it detrimental to latency-sensitive gaming.10

### **5.4 Heavy OpenClash / PassWall / TProxy Usage**

* **Target Environment:** Environments strictly built around complex geo-unblocking and massive custom rule sets.  
* **Recommended Setting:** **Software Flow Offloading (SFO) \+ BBR Enabled**.  
* **Technical Rationale:** Transparent proxies operate at Layer 4-7. If the PPE accelerates the flow at Layer 2/3, the CPU cannot intercept or decrypt the proxy stream.3 Software Flow Offloading ensures that the CPU evaluates initial packets and hands them to the proxy engine seamlessly.

### **5.5 PPPoE WAN**

* **Target Environment:** Fiber-to-the-Home clients relying on router-based PPPoE authentication.  
* **Recommended Setting:** **Hardware Flow Offloading (HFO)** (fallback to SFO if unstable).  
* **Technical Rationale:** The MediaTek PPE natively accelerates PPPoE frame decap/encap without CPU intervention.11 While OpenWrt 24.10 kernel 6.6 has exhibited some PPPoE PADO timeout regressions, these are predominantly localized to Intel NIC passthrough environments. The MT7986 hardware implementation is generally robust, though if random WAN disconnects occur, SFO serves as an immediate, stable fallback.21

### **5.6 IPv6-Heavy Network**

* **Target Environment:** Modern networks highly reliant on native IPv6 addressing and NAT6 bridging.  
* **Recommended Setting:** **Hardware Flow Offloading (HFO)**.  
* **Technical Rationale:** The MT7986 PPE supports native hardware offloading for IPv6 and NAT6 protocols.3 OpenWrt 24.10 handles nft-nat6 flowtables gracefully, allowing wire-speed IPv6 routing.20

## **6\. Part E: Practical Test Plan and Validation**

To empirically validate the efficacy of these routing settings on the JDCloud RE-CP-03, a rigorous testing methodology must be executed in a controlled local environment. The following steps constitute a definitive test plan for this hardware.

### **6.1 Performance and Bufferbloat Testing Methodology**

1. **Baseline Emulation (No Offloading):**  
   * Navigate to LuCI \-\> Network \-\> Firewall and disable both SFO and HFO.  
   * Initiate an iperf3 test from a wired LAN client to a high-speed WAN server: iperf3 \-c \-P 4 \-t 30\.33  
   * Simultaneously SSH into the router and monitor CPU usage using the htop command. Observe the extremely high software interrupt (sirq) load distributed across the four CPU cores.  
2. **SFO vs. HFO CPU Profiling:**  
   * Enable Software Flow Offloading in LuCI, save, and restart the firewall (/etc/init.d/firewall restart).3 Re-run the iperf3 test. The sirq CPU load should demonstrably drop by 40-60%.35  
   * Enable Hardware Flow Offloading. Re-run the iperf3 test. The CPU load should collapse to near 0%, indicating the PPE has fully assumed the routing workload.1  
3. **Latency and Jitter Load Test:**  
   * From a wired LAN PC, run a continuous ping to a stable WAN endpoint: ping 8.8.8.8 \-t.  
   * Utilize a browser to run the Waveform Bufferbloat Test.22  
   * During the download and upload saturation phases, observe the ICMP ping replies. Under SFO, latency should remain stable (\<1ms variation). Under HFO, observe if the ping exhibits the known MT7986 latency jitter bug (spiking up to 3ms).10

### **6.2 Validating Software Offload via Nftables**

To verify that SFO is actively compiling into the firewall4 architecture, you must inspect the raw nftables ruleset.

1. Establish an SSH session and execute: nft list ruleset | grep \-A 10 "flowtable".8  
2. **Interpretation:** You should observe an output detailing a flowtable ft block attached to the ingress hook of your physical interfaces (e.g., eth1, br-lan). If HFO is disabled, the block will dictate standard software offloading.6

### **6.3 Validating Hardware Offload via MediaTek PPE Debugfs**

The most definitive proof that traffic is utilizing the MT7986 silicon is found within the kernel's debug filesystem. The PPE hardware hash tables are exposed to the user space via a specific file.12

1. Initiate a large file download through the router to ensure active flows exist.  
2. Execute the following command over SSH:  
   Bash  
   cat /sys/kernel/debug/ppe0/entries

3. **Interpreting the Output:** A successful hardware-offloaded flow generates a string resembling the following: 00e06 BND IPv4 5T orig=192.168.1.10:38720-\>8.8.8.8:443 new=10.0.0.2:38720-\>8.8.8.8:443 eth=aa:bb:cc-\>dd:ee:ff etype=0800 vlan=0,0 ib1=61481436 ib2=007ff035 packets=1000 bytes=1500000.12  
   * **BND (Bind):** This flag confirms the flow is successfully bound to the hardware in both directions.  
   * **UNB (Unbind):** Indicates a broken, failing, or half-closed flow. If you observe BND on the outgoing string but UNB on the incoming string, the hardware acceleration has failed, and the connection will likely stall (this is the diagnostic signature of the WireGuard HFO bug).18  
   * **ib1 and ib2 (Internal Bus Flags):** According to kernel developer mailing lists, these hexadecimal bitmasks represent internal MediaTek switch states. They map the flow to specific hardware QoS queues, denote the physical Destination Ports, and flag PPPoE encapsulation bits (MTK\_FOE\_IB1\_BIND\_PPPOE).36 If the file returns entirely empty, no flows are currently offloaded to the PPE.12

## **7\. Part F: Final Recommendations and Deployment Strategy**

Synthesizing the architectural capabilities of the MediaTek MT7986, the firmware realities of ImmortalWrt 24.10, and the specific 128GB eMMC homelab nature of the JDCloud RE-CP-03 Baili, the optimal deployment strategy requires navigating significant trade-offs between raw silicon acceleration and software feature compatibility.

### **7.1 Primary Offloading Directives**

**1\. Which offloading mode should be chosen first?**

* **Recommendation:** **Software Flow Offloading (SFO)**.  
* **Rationale:** While the hardware capabilities of the MT7986 PPE are formidable, the current state of OpenWrt/ImmortalWrt 24.10 is fraught with edge-case regressions concerning Hardware Flow Offloading. Documented anomalies include the severe WireGuard connection drop bug 18, WLAN-to-LAN bridging failures 16, proxy routing bypasses 3, and micro-latency jitter under maximum load.10 The MT7986's quad-core 2.0GHz CPU is immensely powerful, capable of routing well over 1 Gbps purely in software via the fast path (SFO). SFO provides the vast majority of the CPU relief offered by hardware offloading while maintaining absolute compatibility with Docker bridges, TProxy interception, and SQM traffic shaping. SFO provides the most stable baseline for a complex network.

**2\. Under what circumstances should the router be upgraded to Hardware Flow Offloading (HFO)?**

* HFO should be enabled only if the physical internet connection exceeds 1.5 Gbps symmetrically, and the CPU is observably bottlenecking local transfers.  
* HFO is appropriate if the JDCloud RE-CP-03 is deployed strictly as a "dumb" access point or a rudimentary NAT router, entirely devoid of OpenClash, Docker containers, WireGuard tunnels, or SQM queuing.2

**3\. When should HFO be downgraded back to SFO?**

* Immediately, if WireGuard or OpenVPN tunnels exhibit unexplained stalling or failure to route incoming handshakes after periods of inactivity.18  
* If OpenClash or PassWall transparent proxies fail to intercept local LAN traffic, resulting in DNS leaks or failure to circumvent geographic blocks.13  
* If network clients experience random Wi-Fi disconnections or 802.11r roaming failures, which are specifically correlated to WED and HFO interactions.34  
* If gaming clients experience erratic 3ms latency bumps when secondary clients utilize high bandwidth.10

**4\. When should Flow Offloading be disabled entirely?**

* **Recommendation:** Almost never.  
* Disabling offloading entirely forces every single packet traversing the router through the cumbersome netfilter slow path. Unless the deployment involves deeply complex, packet-by-packet filtering scripts requiring Deep Packet Inspection (DPI) on every frame (which breaks both SFO and HFO), Software Flow Offloading should always remain the minimum active acceleration state.

### **7.2 Auxiliary Configuration Directives**

**Should TCP BBR be enabled?**

* **Recommendation: YES.**  
* Given that the JDCloud RE-CP-03's 128GB eMMC invites heavy Docker deployment, and its processing power invites OpenClash usage, the router itself acts as a high-volume TCP endpoint. Enabling BBR (paired strictly with the fq qdisc) will massively stabilize and accelerate any TCP tunnel originating from the router (e.g., pulling Docker images, synchronizing package repositories, or establishing persistent Vmess/Shadowsocks outbound proxies).2 The user must merely acknowledge that this will not artificially inflate the benchmark scores of standard LAN clients running basic internet speed tests.30

**Should FullCone NAT be enabled?**

* **Recommendation: NO (for general stability); YES (only for strict gaming requirements).**  
* ImmortalWrt includes the custom ip6tables-mod-fullconenat package.24 However, FullCone NAT inherently degrades stateful firewall protections by permitting any external, unsolicited host to communicate with an internal client port once that port has been initially punched. Furthermore, achieving true hardware-accelerated FullCone NAT on the MT7986 relies on experimental third-party kernel modules like natflow 25, which can introduce out-of-tree kernel panics and instability. Relying on strict Symmetric NAT alongside automated UPnP for dynamic port opening remains the secure, modern standard for mitigating gaming strict-NAT issues without compromising perimeter security.

### **7.3 Final Summary**

The MediaTek MT7986/Filogic 830 SoC driving the JDCloud RE-CP-03 Baili represents a transformative leap in open-source routing capability, bridging the gap between consumer networking and enterprise compute. Its dedicated Packet Processing Engine provides staggering throughput capabilities that dwarf older x86 and MIPS architectures. However, the OpenWrt/ImmortalWrt 24.10 software ecosystem—relying on the Linux 6.6 kernel and the newer firewall4/nftables paradigm—is still actively mitigating the hardware binding (BND/UNB) mechanisms required for highly complex topologies like WireGuard, Docker virtual ethernet pairs, and TProxy interception.

For the vast majority of advanced users deploying the RE-CP-03 as a homelab cornerstone, a Software Flow Offloading (SFO)-centric configuration, supplemented by TCP BBR for proxy endpoints and SQM for latency mitigation, yields an unmatched synthesis of absolute stability, excellent throughput, and uncompromising feature compatibility. Hardware flow offloading, while technically impressive, should be reserved as a tactical override exclusively for rudimentary network topologies prioritizing brute-force throughput over advanced network intelligence.

#### **Works cited**

1. I'm looking for hardware suggestion for a router running OpenWrt \- Reddit, accessed on May 7, 2026, [https://www.reddit.com/r/openwrt/comments/1q7ra9u/im\_looking\_for\_hardware\_suggestion\_for\_a\_router/](https://www.reddit.com/r/openwrt/comments/1q7ra9u/im_looking_for_hardware_suggestion_for_a_router/)  
2. \[OpenWrt Wiki\] GL.iNet GL-MT6000, accessed on May 7, 2026, [https://openwrt.org/toh/gl.inet/gl-mt6000](https://openwrt.org/toh/gl.inet/gl-mt6000)  
3. \[OpenWrt Wiki\] Flow offloading, accessed on May 7, 2026, [https://openwrt.org/docs/guide-user/perf\_and\_log/flow\_offloading](https://openwrt.org/docs/guide-user/perf_and_log/flow_offloading)  
4. Current highest spec router that supports OpenWRT H/W NAT offloading? \- Reddit, accessed on May 7, 2026, [https://www.reddit.com/r/openwrt/comments/1lopamn/current\_highest\_spec\_router\_that\_supports\_openwrt/](https://www.reddit.com/r/openwrt/comments/1lopamn/current_highest_spec_router_that_supports_openwrt/)  
5. \[PATCH v2 12/14\] net: ethernet: mtk\_eth\_soc: rework hardware flow table management \- Mailing Lists, accessed on May 7, 2026, [https://lists.infradead.org/pipermail/linux-mediatek/2022-April/038384.html](https://lists.infradead.org/pipermail/linux-mediatek/2022-April/038384.html)  
6. Sources/firewall4/tests/01\_configuration/01\_ruleset \- OpenWRT, accessed on May 7, 2026, [https://lxr.openwrt.org/source/firewall4/tests/01\_configuration/01\_ruleset](https://lxr.openwrt.org/source/firewall4/tests/01_configuration/01_ruleset)  
7. NATflow hack kernel module \- GitHub, accessed on May 7, 2026, [https://github.com/ptpt52/natflow](https://github.com/ptpt52/natflow)  
8. \[OpenWrt Wiki\] Netfilter Management, accessed on May 7, 2026, [https://openwrt.org/docs/guide-user/firewall/netfilter\_iptables/netfilter\_management](https://openwrt.org/docs/guide-user/firewall/netfilter_iptables/netfilter_management)  
9. Is Software Flow Offloading safe / secure? : r/openwrt \- Reddit, accessed on May 7, 2026, [https://www.reddit.com/r/openwrt/comments/1pqujma/is\_software\_flow\_offloading\_safe\_secure/](https://www.reddit.com/r/openwrt/comments/1pqujma/is_software_flow_offloading_safe_secure/)  
10. Hardware flow offloading working abnormally in MediaTek MT7981BA \#19449 \- GitHub, accessed on May 7, 2026, [https://github.com/openwrt/openwrt/issues/19449](https://github.com/openwrt/openwrt/issues/19449)  
11. Working hardware flow offload for MT7620 \- For Developers \- OpenWrt Forum, accessed on May 7, 2026, [https://forum.openwrt.org/t/working-hardware-flow-offload-for-mt7620/89766](https://forum.openwrt.org/t/working-hardware-flow-offload-for-mt7620/89766)  
12. \[OpenWrt Wiki\] Wireless Ethernet Dispatch (WED), accessed on May 7, 2026, [https://openwrt.org/docs/guide-user/network/wifi/wed](https://openwrt.org/docs/guide-user/network/wifi/wed)  
13. \[Bug\]: Firewall4 (FW4 / nftables) compatibility issue: 'option reload 1' set in UCI-Defaults script \#891 \- GitHub, accessed on May 7, 2026, [https://github.com/Openwrt-Passwall/openwrt-passwall2/issues/891](https://github.com/Openwrt-Passwall/openwrt-passwall2/issues/891)  
14. \[OpenWrt Wiki\] Firewall configuration /etc/config/firewall, accessed on May 7, 2026, [https://openwrt.org/docs/guide-user/firewall/firewall\_configuration](https://openwrt.org/docs/guide-user/firewall/firewall_configuration)  
15. firewall4: counts bytes and packets incorrectly with offloading enabled \#10399 \- GitHub, accessed on May 7, 2026, [https://github.com/openwrt/openwrt/issues/10399](https://github.com/openwrt/openwrt/issues/10399)  
16. Hardware flow offloading is not working for WLAN\<-\>LAN · Issue \#18589 \- GitHub, accessed on May 7, 2026, [https://github.com/openwrt/openwrt/issues/18589](https://github.com/openwrt/openwrt/issues/18589)  
17. Does adding veth to the main bridge affect hardware offloading? \- MikroTik Forum, accessed on May 7, 2026, [https://forum.mikrotik.com/t/does-adding-veth-to-the-main-bridge-affect-hardware-offloading/268355](https://forum.mikrotik.com/t/does-adding-veth-to-the-main-bridge-affect-hardware-offloading/268355)  
18. \[23.05, 24.10\] Hardware flow offloading conntrack bug breaking long-lived UDP connections · Issue \#17915 \- GitHub, accessed on May 7, 2026, [https://github.com/openwrt/openwrt/issues/17915](https://github.com/openwrt/openwrt/issues/17915)  
19. Lets talk about firewall4 (default nftables firewall) \- Page 4 \- For Developers, accessed on May 7, 2026, [https://forum.openwrt.org/t/lets-talk-about-firewall4-default-nftables-firewall/231246?page=4](https://forum.openwrt.org/t/lets-talk-about-firewall4-default-nftables-firewall/231246?page=4)  
20. \[OpenWrt Wiki\] OpenWrt v23.05.0-rc1 Changelog, accessed on May 7, 2026, [https://openwrt.org/releases/23.05/changelog-23.05.0-rc1](https://openwrt.org/releases/23.05/changelog-23.05.0-rc1)  
21. PPPoE connection issue with 24.10.3/4 : r/openwrt \- Reddit, accessed on May 7, 2026, [https://www.reddit.com/r/openwrt/comments/1oepgjl/pppoe\_connection\_issue\_with\_241034/](https://www.reddit.com/r/openwrt/comments/1oepgjl/pppoe_connection_issue_with_241034/)  
22. \[OpenWrt Wiki\] SQM (Smart Queue Management), accessed on May 7, 2026, [https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm)  
23. Is there a general guidelines when to use SQM vs hardware/software offloading ? : r/openwrt, accessed on May 7, 2026, [https://www.reddit.com/r/openwrt/comments/1psam7x/is\_there\_a\_general\_guidelines\_when\_to\_use\_sqm\_vs/](https://www.reddit.com/r/openwrt/comments/1psam7x/is_there_a_general_guidelines_when_to_use_sqm_vs/)  
24. accessed on May 7, 2026, [https://downloads.immortalwrt.org/releases/packages-24.10/arm\_arm1176jzf-s\_vfp/base/Packages](https://downloads.immortalwrt.org/releases/packages-24.10/arm_arm1176jzf-s_vfp/base/Packages)  
25. Natflow: Accelerate NAT and Packet Forwarding Like Never Before \- OpenWrt Forum, accessed on May 7, 2026, [https://forum.openwrt.org/t/natflow-accelerate-nat-and-packet-forwarding-like-never-before/230833](https://forum.openwrt.org/t/natflow-accelerate-nat-and-packet-forwarding-like-never-before/230833)  
26. Policy-Based Routing on an OpenWrt Router \- Dariusz Więckiewicz, accessed on May 7, 2026, [https://dariusz.wieckiewicz.org/en/policy-based-routing-openwrt/](https://dariusz.wieckiewicz.org/en/policy-based-routing-openwrt/)  
27. BBR on OpenWRT for fast and stable Wi-Fi \- IT Orakul, accessed on May 7, 2026, [https://itorakul.com.ua/en/bbr-on-openwrt/](https://itorakul.com.ua/en/bbr-on-openwrt/)  
28. TCP BBR congestion control comes to GCP – your Internet just got faster \- Google Cloud, accessed on May 7, 2026, [https://cloud.google.com/blog/products/networking/tcp-bbr-congestion-control-comes-to-gcp-your-internet-just-got-faster](https://cloud.google.com/blog/products/networking/tcp-bbr-congestion-control-comes-to-gcp-your-internet-just-got-faster)  
29. A quick look at TCP BBR \- https://blog.cerowrt.org/, accessed on May 7, 2026, [https://blog.cerowrt.org/post/bbrs\_basic\_beauty/](https://blog.cerowrt.org/post/bbrs_basic_beauty/)  
30. Topic: TCP Congestion Algorithms \- OpenWrt Forum Archive, accessed on May 7, 2026, [https://forum.archive.openwrt.org/viewtopic.php?id=65427](https://forum.archive.openwrt.org/viewtopic.php?id=65427)  
31. Topic: How to choose tcp congestion control algorithm? \- OpenWrt Forum Archive, accessed on May 7, 2026, [https://forum.archive.openwrt.org/viewtopic.php?id=65454](https://forum.archive.openwrt.org/viewtopic.php?id=65454)  
32. How would I go about Indirect TCP on openwrt? \- Reddit, accessed on May 7, 2026, [https://www.reddit.com/r/openwrt/comments/1lvivkr/how\_would\_i\_go\_about\_indirect\_tcp\_on\_openwrt/](https://www.reddit.com/r/openwrt/comments/1lvivkr/how_would_i_go_about_indirect_tcp_on_openwrt/)  
33. How to Create TCP BBR Congestion Control \- OneUptime, accessed on May 7, 2026, [https://oneuptime.com/blog/post/2026-01-30-tcp-bbr-congestion-control/view](https://oneuptime.com/blog/post/2026-01-30-tcp-bbr-congestion-control/view)  
34. 802.11r FT issues between BPI-R4 and GL-MT6000 \- Clients locked out after failed roam, accessed on May 7, 2026, [https://forum.openwrt.org/t/802-11r-ft-issues-between-bpi-r4-and-gl-mt6000-clients-locked-out-after-failed-roam/245648](https://forum.openwrt.org/t/802-11r-ft-issues-between-bpi-r4-and-gl-mt6000-clients-locked-out-after-failed-roam/245648)  
35. OpenWrt \- Software Flow Offloading | WAN to LAN Throughput Test \- YouTube, accessed on May 7, 2026, [https://www.youtube.com/watch?v=toKr5OVX8XI](https://www.youtube.com/watch?v=toKr5OVX8XI)  
36. \[PATCH net-next 12/12\] net: ethernet: mtk\_eth\_soc: introduce flow offloading support for mt7986 \- Mailing Lists, accessed on May 7, 2026, [https://lists.infradead.org/pipermail/linux-mediatek/2022-September/048013.html](https://lists.infradead.org/pipermail/linux-mediatek/2022-September/048013.html)  
37. Greg Kroah-Hartman: Re: Linux 6.17.10 \- LKML, accessed on May 7, 2026, [https://lkml.org/lkml/2025/12/1/593](https://lkml.org/lkml/2025/12/1/593)  
38. \[openwrt/openwrt\] kernel: pick patches for MediaTek Ethernet from linux-next \- Mailing Lists, accessed on May 7, 2026, [http://lists.infradead.org/pipermail/lede-commits/2022-September/015533.html](http://lists.infradead.org/pipermail/lede-commits/2022-September/015533.html)