# Network Structura
resource "libvirt_network" "kube_network" {
  name      = "k8snet"
  autostart = true
  bridge = {
    name = "virbr-k8s"
  }

  forward = {
    mode = "nat"
  }

  ips = [
    {
      address = "10.10.10.1"
      netmask = "255.255.255.0"
      dhcp = {
        ranges = [
          {
            start = "10.10.10.100"
            end   = "10.10.10.200"
          }
        ]
      }
    }
  ]

}
# Storage Pool
resource "libvirt_pool" "kube_pool" {
  name = "k8spool"
  type = "dir"
  target = {
    path = "/var/lib/libvirt/storage/images/pool_img/"
    permissions = {
      group = "0"
      mode  = "0711"
      owner = "0"
    }
  }
  create = {
    autostart = true
    build     = true
    start     = true
  }
  destroy = {
    delete = false
  }
}

# Volume from HTTP URL upload
resource "libvirt_volume" "ubuntu_base" {
  name = "ubuntu-22.04.qcow2"
  pool = libvirt_pool.kube_pool.name
  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = "/home/hafisquliyev/baremetal/images/ubuntu-22.04-server-cloudimg-arm64.img"
    }
  }
  # capacity is automatically computed from Content-Length when available
}

locals {
  nodes = {
    k8s-master = {
      role    = "master"
      ip      = "10.10.10.11"
      vcpu    = 2
      ram_mb  = 4096
      disk_gb = 20
    }
    k8s-worker-1 = {
      role    = "worker"
      ip      = "10.10.10.12"
      vcpu    = 2
      ram_mb  = 2048
      disk_gb = 20
    }
    k8s-worker-2 = {
      role    = "worker"
      ip      = "10.10.10.13"
      vcpu    = 2
      ram_mb  = 2048
      disk_gb = 20
    }
  }
}

resource "libvirt_volume" "node_disk" {
  for_each = local.nodes
  name     = "${each.key}.qcow2" #k8s-master.qcow2 , k8s-worker-1.qcow2 , k8s-worker-2.qcow2
  pool     = libvirt_pool.kube_pool.name
  capacity = each.value.disk_gb * 1024 * 1024 * 1024
  target = {
    format = {
      type = "qcow2"
    }
  }
  backing_store = {
    path = libvirt_volume.ubuntu_base.path
    format = {
      type = "qcow2"
    }
  }
}
resource "libvirt_cloudinit_disk" "init" {
  for_each  = local.nodes
  meta_data = <<-EOT
    instance-id: ${each.key}-001
    localhost-name: ${each.key}
  EOT
  user_data = file("${path.module}/cloud-init/user-data.tftpl")
  name      = "${each.key}-init.iso"
  network_config = templatefile(
    "${path.module}/cloud-init/network-config.tftpl",
    { ip = each.value.ip }
  )
}

resource "libvirt_volume" "seed" {
  for_each = local.nodes
  name     = "${each.key}-seed.iso"
  pool     = libvirt_pool.kube_pool.name

  create = {
    content = {
      url = libvirt_cloudinit_disk.init[each.key].path
    }
  }
}
resource "libvirt_domain" "node" {
  for_each = local.nodes

  name        = each.key
  type        = "kvm"
  memory      = each.value.ram_mb
  memory_unit = "MiB"
  vcpu        = each.value.vcpu
  running     = true

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.node_disk[each.key].pool
            volume = libvirt_volume.node_disk[each.key].name
          }
        }
        target = { dev = "vda", bus = "virtio" }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.seed[each.key].pool
            volume = libvirt_volume.seed[each.key].name
          }
        }
        target = { dev = "sdb", bus = "sata" }
      }
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = "libvirt_network.kube_network.name"
          }
        }
      }
    ]
  }
}
