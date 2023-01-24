# frozen_string_literal: true

# Copyright (c) [2022-2023] SUSE LLC
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

require "dbus"
require "dinstaller/dbus/base_object"
require "dinstaller/dbus/with_service_status"
require "dinstaller/dbus/interfaces/progress"
require "dinstaller/dbus/interfaces/service_status"
require "dinstaller/dbus/interfaces/validation"
require "dinstaller/dbus/storage/proposal_settings_converter"
require "dinstaller/dbus/storage/volume_converter"

module DInstaller
  module DBus
    module Storage
      # D-Bus object to manage storage installation
      class Manager < BaseObject
        include WithServiceStatus
        include DBus::Interfaces::Progress
        include DBus::Interfaces::ServiceStatus
        include DBus::Interfaces::Validation

        PATH = "/org/opensuse/DInstaller/Storage1"
        private_constant :PATH

        # Constructor
        #
        # @param backend [DInstaller::Storage::Manager]
        # @param logger [Logger]
        def initialize(backend, logger)
          super(PATH, logger: logger)
          @backend = backend
          register_proposal_callbacks
          register_progress_callbacks
          register_service_status_callbacks
        end

        STORAGE_INTERFACE = "org.opensuse.DInstaller.Storage1"
        private_constant :STORAGE_INTERFACE

        dbus_interface STORAGE_INTERFACE do
          dbus_method(:Probe) { probe }
          dbus_method(:Install) { install }
          dbus_method(:Finish) { finish }
        end

        def probe
          busy_while { backend.probe }
        end

        def install
          busy_while { backend.install }
        end

        def finish
          busy_while { backend.finish }
        end

        PROPOSAL_CALCULATOR_INTERFACE = "org.opensuse.DInstaller.Storage1.Proposal.Calculator"
        private_constant :PROPOSAL_CALCULATOR_INTERFACE

        dbus_interface PROPOSAL_CALCULATOR_INTERFACE do
          dbus_reader :available_devices, "a(ssa{sv})"

          dbus_reader :volume_templates, "aa{sv}"

          # result: 0 success; 1 error
          dbus_method :Calculate, "in settings:a{sv}, out result:u" do |settings|
            busy_while { calculate_proposal(settings) }
          end
        end

        # List of disks available for installation
        #
        # Each device is represented by an array containing the name of the device and the label to
        # represent that device in the UI when further information is needed.
        #
        # @return [Array<String, String, Hash>]
        def available_devices
          proposal.available_devices.map do |dev|
            [dev.name, proposal.device_label(dev), {}]
          end
        end

        # Volumes used as template for creating a new proposal
        #
        # @return [Hash]
        def volume_templates
          converter = VolumeConverter.new
          proposal.volume_templates.map { |v| converter.to_dbus(v) }
        end

        # Calculates a new proposal
        #
        # @param dbus_settings [Hash]
        # @return [Integer] 0 success; 1 error
        def calculate_proposal(dbus_settings)
          logger.info("Calculating storage proposal from D-Bus settings: #{dbus_settings}")

          converter = ProposalSettingsConverter.new
          success = proposal.calculate(converter.to_dinstaller(dbus_settings))

          success ? 0 : 1
        end

      private

        # @return [DInstaller::Storage::Manager]
        attr_reader :backend

        # @return [DInstaller::Storage::Proposal]
        def proposal
          backend.proposal
        end

        def register_proposal_callbacks
          proposal.on_calculate { update_validation }
        end
      end
    end
  end
end
