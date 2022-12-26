require "socket"

class Packet
    attr_accessor :bytes, :l3, :l4, :l4_start

    def initialize(bytes)
        self.bytes = bytes
        self.l3 = IPv4.parse(self)
        if self.l3
            if self.l3.proto == UDP::PROTOCOL_ID
                self.l4 = UDP.parse(self)
            elsif self.l3.proto == TCP::PROTOCOL_ID
                self.l4 = TCP.parse(self)
            elsif self.l3.proto == ICMP::PROTOCOL_ID
                self.l4 = ICMP.parse(self)
            end
        end
    end

    def apply()
        orig_l3_tuple = l3._apply(self)
        l4._apply(self, orig_l3_tuple)
    end

    def decode_u16(off)
        @bytes[off .. off + 1].unpack1("n")
    end

    def encode_u16(off, v)
        # this seems faster than pack-then-replace
        @bytes[off] = ((v >> 8) & 0xff).chr
        @bytes[off + 1] = (v & 0xff).chr
    end
end

class IP
    attr_accessor :src_addr, :dest_addr
    attr_reader :proto

    def self.checksum(bytes, from = nil, len = nil)
        from = 0 if from.nil?
        len = bytes.length - from if len.nil?
        to = from + len - 1

        sum = bytes[from .. to].unpack("n*").sum
        if len % 2 != 0
            sum += bytes[to].ord * 256
        end
        ~((sum >> 16) + sum) & 0xffff
    end

    # fom RFC 3022 4.2
    def self.checksum_adjust(sum, old_bytes, new_bytes)
        sum = ~sum & 0xffff;
        for u16 in old_bytes.unpack("n*")
            sum -= u16;
            if sum <= 0
                sum -= 1
                sum &= 0xffff
            end
        end
        for u16 in new_bytes.unpack("n*")
            sum += u16;
            if sum >= 0x10000
                sum += 1
                sum &= 0xffff
            end
        end
        ~sum & 0xffff
    end
end

class IPv4 < IP
    PROTOCOL_ID = 0x0800

    def _parse(packet)
        bytes = packet.bytes

        return nil if bytes.length < 20
        return nil if bytes[0].ord != 0x45
        # tos?
        # totlen?
        # ignore identification
        return nil if packet.decode_u16(6) & 0xbfff != 0 # ignore fragments
        # ttl: 8
        @proto = bytes[9].ord
        # checksum 10..11
        @src_addr = bytes[12..15]
        @dest_addr = bytes[16..19]

        packet.l4_start = 20
        self
    end

    def self.parse(packet)
        IPv4.new._parse(packet)
    end

    def tuple()
        @src_addr + @dest_addr
    end

    def _apply(packet)
        bytes = packet.bytes

        orig_tuple = bytes[12..19]

        # decrement TTL
        bytes[8] = (bytes[8].ord - 1).chr

        bytes[12..15] = @src_addr
        bytes[16..19] = @dest_addr

        packet.encode_u16(10, 0)
        checksum = IP.checksum(bytes, 0, packet.l4_start)
        packet.encode_u16(10, checksum)

        orig_tuple
    end

    def self.addr_to_s(addr)
        addr.unpack("C4").join(".")
    end
end

class UDP
    PROTOCOL_ID = 17

    attr_accessor :src_port, :dest_port

    def _parse(packet)
        off = packet.l4_start

        return nil if packet.bytes.length - off < 8
        @src_port = packet.decode_u16(off)
        @dest_port = packet.decode_u16(off + 2)
        # length 2 bytes
        # checksum 2 bytes

        self
    end

    def self.parse(packet)
        UDP.new._parse(packet)
    end

    def _apply(packet, orig_l3_tuple)
        bytes = packet.bytes
        l4_start = packet.l4_start

        orig_bytes = orig_l3_tuple + bytes[l4_start .. l4_start + 3]

        packet.encode_u16(l4_start, @src_port)
        packet.encode_u16(l4_start + 2, @dest_port)

        new_bytes = packet.l3.tuple + bytes[l4_start .. l4_start + 3]

        checksum = packet.decode_u16(packet.l4_start + 6)
        checksum = IP.checksum_adjust(checksum, orig_bytes, new_bytes)
        packet.encode_u16(packet.l4_start + 6, checksum)
    end
end

class TCP
    PROTOCOL_ID = 6

    attr_accessor :src_port, :dest_port
    attr_reader :flags

    def _parse(packet)
        off = packet.l4_start

        return nil if packet.bytes.length - off < 20
        @src_port = packet.decode_u16(off)
        @dest_port = packet.decode_u16(off + 2)
        # seq 4 bytes
        # ack 4 bytes
        @flags = packet.decode_u16(off + 12)
        # winsz 2 bytes
        # checksum 2 bytes

        self
    end

    def self.parse(packet)
        TCP.new._parse(packet)
    end

    def _apply(packet, orig_l3_tuple)
        bytes = packet.bytes
        l4_start = packet.l4_start

        orig_bytes = orig_l3_tuple + bytes[l4_start .. l4_start + 3]

        packet.encode_u16(l4_start, @src_port)
        packet.encode_u16(l4_start + 2, @dest_port)

        new_bytes = packet.l3.tuple + bytes[l4_start .. l4_start + 3]

        checksum = packet.decode_u16(l4_start + 16)
        checksum = IP.checksum_adjust(checksum, orig_bytes, new_bytes)
        packet.encode_u16(packet.l4_start + 16, checksum)
    end
end

class ICMP
    PROTOCOL_ID = 1

    attr_reader :type, :code, :checksum

    def _parse(packet)
        bytes = packet.bytes
        off = packet.l4_start

        @type = bytes[off].ord
        @code = bytes[off + 1].ord
        @checksum = packet.decode_u16(off + 2)

        self
    end

    def self.parse(packet)
        bytes = packet.bytes
        off = packet.l4_start

        return nil if bytes.length - off < 8

        type = bytes[off].ord
        if type == ICMPDestUnreach::TYPE
            icmp = ICMPDestUnreach.new
        else
            icmp = ICMP.new
        end

        icmp._parse(packet)
    end

    def _apply(packet, orig_l3_tuple)
        # ICMP does not use pseudo headers
    end
end

class ICMPDestUnreach < ICMP
    TYPE = 3

    attr_reader :orig_proto
    attr_accessor :orig_src_addr, :orig_dest_addr, :orig_src_port, :orig_dest_port

    def _parse(packet)
        if super(packet).nil?
            return nil
        end

        @orig_packet = Packet.new(packet.bytes[packet.l4_start + 8 ..])
        if @orig_packet.nil?
            return nil
        end

        if @orig_packet.l4.nil?
            puts "FIXME DestUnreach does not fully contain original L4 header? That's allowed in spec"
            return nil
        end

        @orig_proto = @orig_packet.l3.proto
        @orig_src_addr = @orig_packet.l3.src_addr
        @orig_dest_addr = @orig_packet.l3.dest_addr
        @orig_src_port = @orig_packet.decode_u16(@orig_packet.l4_start)
        @orig_dest_port = @orig_packet.decode_u16(@orig_packet.l4_start + 2)

        self
    end

    def _apply(packet, orig_l3_tuple)
        # update 4 tuple of orig_packet
        @orig_packet.l3.src_addr = @orig_src_addr
        @orig_packet.l3.dest_addr = @orig_dest_addr
        @orig_packet.l4.src_port = @orig_src_port
        @orig_packet.l4.dest_port = @orig_dest_port
        @orig_packet.apply

        # overwrite packet image with orig packet being built
        packet.bytes[packet.l4_start + 8 ..] = @orig_packet.bytes

        # recalculate checksum
        packet.encode_u16(packet.l4_start + 2, 0)
        @checksum = IP.checksum(packet.bytes, packet.l4_start, packet.bytes.length - packet.l4_start)
        packet.encode_u16(packet.l4_start + 2, @checksum)
    end
end

class Tun
    IFF_TUN = 1
    IFF_NO_PI = 0x1000
    TUNSETIFF = 0x400454ca

    def initialize(devname)
        @tundev = open("/dev/net/tun", "r+")

        ifreq = [devname, IFF_TUN | IFF_NO_PI].pack("a" + Socket::IFNAMSIZ.to_s + "s!")
        @tundev.ioctl(TUNSETIFF, ifreq)
    end

    def read()
        bytes = @tundev.sysread(1500)
        return Packet.new(bytes)
    end

    def write(packet)
        @tundev.syswrite(packet.bytes)
    end
end
