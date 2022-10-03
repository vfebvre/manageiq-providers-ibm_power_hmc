class ManageIQ::Providers::IbmPowerHmc::Inventory::Parser::InfraManager < ManageIQ::Providers::IbmPowerHmc::Inventory::Parser
  def parse
    $ibm_power_hmc_log.info("#{self.class}##{__method__} start")
    collector.collect! do
      parse_cecs
      parse_lpars
      parse_vioses
      parse_templates
      parse_ssps
    end
    $ibm_power_hmc_log.info("#{self.class}##{__method__} end")
  end

  def parse_cecs
    collector.cecs.each do |sys|
      host = persister.hosts.build(
        :uid_ems             => sys.uuid,
        :ems_ref             => sys.uuid,
        :name                => sys.name,
        :hypervisor_hostname => "#{sys.mtype}#{sys.model}_#{sys.serial}",
        :hostname            => sys.hostname,
        :ipaddress           => sys.ipaddr,
        :power_state         => lookup_power_state(sys.state),
        :vmm_vendor          => "ibm_power_hmc",
        :type                => ManageIQ::Providers::IbmPowerHmc::InfraManager::Host.name
      )

      parse_host_operating_system(host, sys)
      parse_host_hardware(host, sys)
      parse_host_advanced_settings(host, sys)
      parse_vswitches(host, sys)
      parse_vlans(host, sys)
    end
  end

  def self.storage_capacity(storage)
    case storage
    when IbmPowerHmc::VirtualOpticalMedia
      storage.size.to_f.gigabytes.to_i
    when IbmPowerHmc::SharedStoragePool, IbmPowerHmc::LogicalUnit
      storage.capacity.to_f.gigabytes.to_i
    else
      storage.capacity.to_i.megabytes
    end
  end

  def parse_ssps
    collector.ssps.each do |ssp|
      persister.storages.build(
        :name        => ssp.name,
        :total_space => self.class.storage_capacity(ssp),
        :ems_ref     => ssp.cluster_uuid,
        :free_space  => ssp.free_space.to_f.gigabytes.round
      )
    end
  end

  def parse_lpar_disks(lpar, hardware)
    collector.vscsi_lun_mappings_by_uuid[lpar.uuid].to_a.each do |mapping|
      found_ssp_uuid = collector.ssp_lus_by_udid[mapping.storage.udid]

      persister.disks.build(
        :device_type => "disk",
        :hardware    => hardware,
        :storage     => persister.storages.lazy_find(found_ssp_uuid),
        :device_name => mapping.storage.name,
        :size        => self.class.storage_capacity(mapping.storage)
      )
    end
  end

  def parse_vios_disks(vios, hardware)
    vios.pvs.each do |pv|
      persister.disks.build(
        :hardware        => hardware,
        :device_type     => "disk",
        :device_name     => pv.name,
        :size            => self.class.storage_capacity(pv),
        :location        => pv.location,
        :controller_type => pv.is_fc == "true" ? "FC" : "SCSI"
      )
    end
  end

  def parse_host_operating_system(host, sys)
    persister.host_operating_systems.build(
      :host         => host,
      :product_name => "phyp",
      :build_number => sys.fwversion
    )
  end

  def parse_host_hardware(host, sys)
    persister.host_hardwares.build(
      :host            => host,
      :cpu_type        => "ppc64",
      :bitness         => 64,
      :manufacturer    => "IBM",
      :model           => "#{sys.mtype}#{sys.model}",
      :memory_mb       => sys.memory,
      :cpu_total_cores => sys.cpus,
      :serial_number   => sys.serial
    )
  end

  def parse_host_advanced_settings(host, sys)
    if collector.pcm_enabled[sys.uuid]
      persister.hosts_advanced_settings.build(
        :resource     => host,
        :name         => "pcm_enabled",
        :display_name => _("PCM-enabled"),
        :description  => _("Performance and Capacity Monitoring data collection enabled"),
        :value        => collector.pcm_enabled[sys.uuid].aggregation,
        :read_only    => true
      )
    end
    persister.hosts_advanced_settings.build(
      :resource     => host,
      :name         => "hmc_managed",
      :display_name => _("HMC-managed"),
      :description  => _("The PowerVM management master of this host is a HMC."),
      :value        => sys.is_classic_hmc_mgmt.eql?("true") ? sys.is_classic_hmc_mgmt : sys.is_hmc_mgmt_master,
      :read_only    => true
    )
  end

  def parse_lpars
    collector.lpars.each do |lpar|
      _vm, hardware = parse_lpar_common(lpar, ManageIQ::Providers::IbmPowerHmc::InfraManager::Lpar.name)
      parse_lpar_disks(lpar, hardware)
      parse_lpar_guest_devices(lpar, hardware)
    end
  end

  def parse_vioses
    collector.vioses.each do |vios|
      _vm, hardware = parse_lpar_common(vios, ManageIQ::Providers::IbmPowerHmc::InfraManager::Vios.name)
      parse_vios_disks(vios, hardware)
    end
  end

  def parse_lpar_common(lpar, type)
    # Common code for LPARs and VIOSes.
    host = persister.hosts.lazy_find(lpar.sys_uuid)
    vm = persister.vms.build(
      :type            => type,
      :uid_ems         => lpar.uuid,
      :ems_ref         => lpar.uuid,
      :name            => lpar.name,
      :location        => "unknown",
      :vendor          => "ibm_power_hmc",
      :description     => lpar.description.to_s,
      :raw_power_state => lpar.state,
      :host            => host
    )
    parse_vm_operating_system(vm, lpar)
    parse_vm_advanced_settings(vm, lpar)

    hardware = parse_vm_hardware(vm, lpar)
    parse_vm_networks(lpar, hardware)
    parse_vm_guest_devices(lpar, hardware)

    [vm, hardware]
  end

  def parse_vm_hardware(vm, lpar)
    persister.hardwares.build(
      :vm_or_template  => vm,
      :memory_mb       => lpar.memory,
      :cpu_total_cores => lpar.dedicated.eql?("true") ? lpar.procs.to_i : lpar.vprocs.to_i
    )
  end

  def parse_vm_networks(lpar, hardware)
    if lpar.rmc_ipaddr
      persister.networks.build(
        :ipaddress   => lpar.rmc_ipaddr,
        :ipv6address => nil,
        :hardware    => hardware
      )
    end
  end

  def parse_vswitches(host, sys)
    if collector.vswitches.key?(sys.uuid)
      collector.vswitches[sys.uuid].each do |vswitch|
        switch = persister.host_virtual_switches.build(
          :uid_ems => vswitch.uuid,
          :name    => vswitch.name,
          :host    => host
        )
        persister.host_switches.build(:host => host, :switch => switch)
      end
    end
  end

  def parse_vlans(host, sys)
    if collector.vlans.key?(sys.uuid)
      collector.vlans[sys.uuid].each do |vlan|
        vswitch = persister.host_virtual_switches.lazy_find(:host => host, :uid_ems => vlan.vswitch_uuid)
        persister.lans.build(
          :uid_ems => vlan.uuid,
          :switch  => vswitch,
          :tag     => vlan.vlan_id,
          :name    => vlan.name,
          :ems_ref => sys.uuid
        )
      end
    end
  end

  def parse_vm_operating_system(vm, lpar)
    if lpar.os.nil? || lpar.os.downcase == "unknown"
      # RSCT is not running on the LPAR
      if lpar.respond_to?(:type) && lpar.type == "Virtual IO Server"
        os_info = ["VIOS"]
      end
    else
      # HMC provides the OS version as a flat string.
      # We do our best to extract the name, version and build numbers from this string.
      # Also, HMCs older than v10 have a 32 characters limit on the OS name part.
      # Examples of what we get from HMC/RSCT:
      # "VIOS 3.1.0.11"
      # "AIX 7.3 7300-00-00-0000"
      # "Linux/Debian 4.4.0-87-generic Unknown"
      # "Linux/Hardware Management Conso V10R2 1030"
      # "Linux/Red Hat Enterprise Linux  4.18.0-372.19.1.el8_6.ppc8.4 (Ootpa) 8.4 (Ootpa)"
      # "Linux/Red Hat Enterprise Linux (CoreOS) 4.18.0-372.19.1.el8_6.ppc8.4 (Ootpa) 8.4 (Ootpa)"
      os_info = lpar.os.split
      if os_info.length > 3
        # Split on the first word that contains a digit
        os_info = lpar.os.split(/\s+(?=\S*\d)/, 2)
      end
    end

    if os_info
      persister.operating_systems.build(
        :vm_or_template => vm,
        :product_name   => os_info[0],
        :version        => os_info[1],
        :build_number   => os_info[2]
      )
    end
  end

  def parse_vm_guest_devices(lpar, hardware)
    if collector.netadapters.key?(lpar.uuid)
      collector.netadapters[lpar.uuid].each do |ent|
        build_ethernet_dev(ent, hardware, "client network adapter")
      end
    end

    if collector.sriov_elps.key?(lpar.uuid)
      collector.sriov_elps[lpar.uuid].each do |ent|
        build_ethernet_dev(ent, hardware, "sr-iov")
      end
    end

    lpar.lhea_ports.each do |ent|
      build_ethernet_dev(ent, hardware, "host ethernet adapter")
    end
  end

  def parse_lpar_guest_devices(lpar, hardware)
    if collector.vnics.key?(lpar.uuid)
      collector.vnics[lpar.uuid].each do |ent|
        build_ethernet_dev(ent, hardware, "vnic")
      end
    end
  end

  def parse_vm_advanced_settings(vm, lpar)
    if lpar.respond_to?("id")
      persister.vms_and_templates_advanced_settings.build(
        :resource     => vm,
        :name         => "partition_id",
        :display_name => _("Partition ID"),
        :description  => _("The logical partition number"),
        :value        => lpar.id.to_i,
        :read_only    => true
      )
    end

    if lpar.respond_to?("ref_code")
      persister.vms_and_templates_advanced_settings.build(
        :resource     => vm,
        :name         => "reference_code",
        :display_name => _("Reference Code"),
        :description  => _("The logical partition reference code"),
        :value        => lpar.ref_code,
        :read_only    => true
      )
    end

    unless lpar.proc_units.nil?
      persister.vms_and_templates_advanced_settings.build(
        :resource     => vm,
        :name         => 'entitled_processors',
        :display_name => _('Entitled Processors'),
        :description  => _('The number of entitled processors assigned to the VM'),
        :value        => lpar.proc_units,
        :read_only    => true
      )
    end

    proc_type = lpar.dedicated == "true" ? "dedicated" : lpar.sharing_mode
    persister.vms_and_templates_advanced_settings.build(
      :resource     => vm,
      :name         => 'processor_type',
      :display_name => _('Processor type'),
      :description  => _('dedicated: Dedicated, shared: Uncapped shared, capped: Capped shared'),
      :value        => proc_type,
      :read_only    => true
    )
  end

  def parse_templates
    collector.templates.each do |template|
      t = persister.miq_templates.build(
        :uid_ems         => template.uuid,
        :ems_ref         => template.uuid,
        :name            => template.name,
        :description     => template.description,
        :vendor          => "ibm_power_hmc",
        :template        => true,
        :location        => "unknown",
        :raw_power_state => "never"
      )
      parse_vm_hardware(t, template)
      parse_vm_operating_system(t, template)
      parse_vm_advanced_settings(t, template)
    end
  end

  def lookup_power_state(state)
    # See SystemState.Enum (/rest/api/web/schema/inc/Enumerations.xsd)
    case state.downcase
    when /error.*/                    then "off"
    when "failed authentication"      then "off"
    when "incomplete"                 then "off"
    when "initializing"               then "on"
    when "no connection"              then "unknown"
    when "on demand recovery"         then "off"
    when "operating"                  then "on"
    when /pending authentication.*/   then "off"
    when "power off"                  then "off"
    when "power off in progress"      then "off"
    when "recovery"                   then "off"
    when "standby"                    then "off"
    when "version mismatch"           then "on"
    when "service processor failover" then "off"
    when "unknown"                    then "unknown"
    else                                   "off"
    end
  end

  def build_ethernet_dev(device, hardware, controller_type)
    mac_addr = device.macaddr.downcase.scan(/\w{2}/).join(':')
    id = device.respond_to?(:uuid) ? device.uuid : device.macaddr
    persister.guest_devices.build(
      :hardware        => hardware,
      :uid_ems         => id,
      :device_name     => mac_addr,
      :device_type     => "ethernet",
      :controller_type => controller_type,
      :auto_detect     => true,
      :address         => mac_addr,
      :location        => device.location
    )
  end
end
