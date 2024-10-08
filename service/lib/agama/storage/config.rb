# frozen_string_literal: true

# Copyright (c) [2024] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "agama/storage/configs"

module Agama
  module Storage
    # Settings used to calculate an storage proposal.
    class Config
      # Boot settings.
      #
      # @return [Configs::Boot]
      attr_accessor :boot

      # @return [Array<Configs::Drive>]
      attr_accessor :drives

      # @return [Array]
      attr_accessor :volume_groups

      # @return [Array]
      attr_accessor :md_raids

      # @return [Array]
      attr_accessor :btrfs_raids

      # @return [Array]
      attr_accessor :nfs_mounts

      def initialize
        @boot = Configs::Boot.new
        @drives = []
        @volume_groups = []
        @md_raids = []
        @btrfs_raids = []
        @nfs_mounts = []
      end

      # Creates a config from JSON hash according to schema.
      #
      # @param config_json [Hash]
      # @param product_config [Agama::Config]
      #
      # @return [Storage::Config]
      def self.new_from_json(config_json, product_config:)
        ConfigConversions::FromJSON.new(config_json, product_config: product_config).convert
      end

      # Name of the device that will presumably be used to boot the target system
      #
      # @return [String, nil] nil if there is no enough information to infer a possible boot disk
      def boot_device
        explicit_boot_device || implicit_boot_device
      end

      # Device used for booting the target system
      #
      # @return [String, nil] nil if no disk is explicitly chosen
      def explicit_boot_device
        return nil unless boot.configure?

        boot.device
      end

      # Device that seems to be expected to be used for booting, according to the drive definitions
      #
      # @return [String, nil] nil if the information cannot be inferred from the list of drives
      def implicit_boot_device
        # NOTE: preliminary implementation with very simplistic checks
        root_drive = drives.find do |drive|
          drive.partitions.any? { |p| p.filesystem&.root? }
        end

        root_drive&.found_device&.name
      end

      # Sets min and max sizes for all partitions and logical volumes with default size
      #
      # @param volume_builder [VolumeTemplatesBuilder] used to check the configuration of the
      #   product volume templates
      def calculate_default_sizes(volume_builder)
        default_size_devices.each do |dev|
          dev.size.min = default_size(dev, :min, volume_builder)
          dev.size.max = default_size(dev, :max, volume_builder)
        end
      end

    private

      # return [Array<Configs::Filesystem>]
      def filesystems
        (drives + partitions).map(&:filesystem).compact
      end

      # return [Array<Configs::Partition>]
      def partitions
        drives.flat_map(&:partitions)
      end

      # return [Array<Configs::Partitions>]
      def default_size_devices
        partitions.select { |p| p.size&.default? }
      end

      # Min or max size that should be used for the given partition or logical volume
      #
      # @param device [Configs::Partition] device configured to have a default size
      # @param attr [Symbol] :min or :max
      # @param builder [VolumeTemplatesBuilder] see {#calculate_default_sizes}
      def default_size(device, attr, builder)
        path = device.filesystem&.path || ""
        vol = builder.for(path)
        return fallback_size(attr) unless vol

        # Theoretically, neither Volume#min_size or Volume#max_size can be nil
        # At most they will be zero or unlimited, respectively
        return vol.send(:"#{attr}_size") unless vol.auto_size?

        outline = vol.outline
        size = size_with_fallbacks(outline, attr, builder)
        size = size_with_ram(size, outline)
        size_with_snapshots(size, device, outline)
      end

      # TODO: these are the fallbacks used when constructing volumes, not sure if repeating them
      # here is right
      def fallback_size(attr)
        return Y2Storage::DiskSize.zero if attr == :min

        Y2Storage::DiskSize.unlimited
      end

      # @see #default_size
      def size_with_fallbacks(outline, attr, builder)
        fallback_paths = outline.send(:"#{attr}_size_fallback_for")
        missing_paths = fallback_paths.reject { |p| proposed_path?(p) }

        size = outline.send(:"base_#{attr}_size")
        missing_paths.inject(size) { |total, p| total + builder.for(p).send(:"#{attr}_size") }
      end

      # @see #default_size
      def size_with_ram(initial_size, outline)
        return initial_size unless outline.adjust_by_ram?

        [initial_size, ram_size].max
      end

      # @see #default_size
      def size_with_snapshots(initial_size, device, outline)
        return initial_size unless device.filesystem.btrfs_snapshots?
        return initial_size unless outline.snapshots_affect_sizes?

        if outline.snapshots_size && outline.snapshots_size > DiskSize.zero
          initial_size + outline.snapshots_size
        else
          multiplicator = 1.0 + (outline.snapshots_percentage / 100.0)
          initial_size * multiplicator
        end
      end

      # Whether there is a separate filesystem configured for the given path
      #
      # @param path [String, Pathname]
      # @return [Boolean]
      def proposed_path?(path)
        filesystems.any? { |fs| fs.path?(path) }
      end

      # Return the total amount of RAM as DiskSize
      #
      # @return [DiskSize] current RAM size
      def ram_size
        @ram_size ||= Y2Storage::DiskSize.new(Y2Storage::StorageManager.instance.arch.ram_size)
      end
    end
  end
end
