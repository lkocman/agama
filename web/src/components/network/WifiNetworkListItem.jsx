/*
 * Copyright (c) [2022] SUSE LLC
 *
 * All Rights Reserved.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of version 2 of the GNU General Public License as published
 * by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, contact SUSE LLC.
 *
 * To contact SUSE LLC about this file by physical or electronic mail, you may
 * find current contact information at www.suse.com.
 */

import React from "react";
import { Flex, Radio, Spinner, Split, Text } from "@patternfly/react-core";
import { Icon } from "~/components/layout";
import { WifiNetworkMenu, WifiConnectionForm } from "~/components/network";
import { DeviceState } from "~/client/network/model";
import { _ } from "~/i18n";
import { sprintf } from "sprintf-js";

const networkState = (state) => {
  switch (state) {
    case DeviceState.CONFIG:
      // TRANSLATORS: Wifi network status
      return _("Connecting");
    case DeviceState.ACTIVATED:
      // TRANSLATORS: Wifi network status
      return _("Connected");
    case DeviceState.DEACTIVATING:
      // TRANSLATORS: Wifi network status
      return _("Disconnecting");
    case DeviceState.FAILED:
      return _("Failed");
    case DeviceState.DISCONNECTED:
      // TRANSLATORS: Wifi network status
      return _("Disconnected");
    default:
      return "";
  }
};

const isStateChanging = (network) => {
  const state = network.device?.state;
  return state === DeviceState.CONFIG || state === DeviceState.NEEDAUTH || state === DeviceState.DEACTIVATING || state === DeviceState.FAILED;
};

/**
 * Component for displaying a Wi-Fi network within a NetworkList
 *
 * @param {object} props - component props
 * @param {object} props.networks - the ap/configured network to be displayed
 * @param {boolean} [props.isSelected] - whether the network has been selected by the user
 * @param {boolean} [props.isActive] - whether the network is currently active
 * @param {function} props.onSelect - function to execute when the network is selected
 * @param {function} props.onCancel - function to execute when the selection is cancelled
 */
function WifiNetworkListItem({ network, isSelected, isActive, onSelect, onCancel }) {
  // Do not wait until receive the next D-Bus network event to have the connection object available
  // and display the spinner as soon as possible. I.e., renders it immediately when the user clicks
  // on an already configured network.
  const showSpinner = (isSelected && network.settings && !network.device) || isStateChanging(network);

  return (
    <li
      key={network.ssid}
      data-state={(isSelected && !network.settings && "focused") || null}
    >
      <Flex justifyContent={{ default: "justifyContentSpaceBetween" }}>
        <Radio
          id={network.ssid}
          label={network.ssid}
          description={
            <>
              <Icon name="lock" size="10" fill="grey" /> {network.security.join(", ")}{" "}
              <Icon name="signal_cellular_alt" size="10" fill="grey" /> {network.strength}
            </>
          }
          isChecked={isSelected || isActive || false}
          onClick={onSelect}
        />
        <Split hasGutter>
          {/* TRANSLATORS: %s is replaced by a WiFi network name */}
          {showSpinner && <Spinner size="md" aria-label={sprintf(_("%s connection is waiting for an state change"), network.ssid)} />}
          <Text component="small" className="keep-words">
            {showSpinner && !network.device && _("Connecting")}
            {networkState(network.device?.state)}
          </Text>
          {network.settings &&
            <WifiNetworkMenu settings={network.settings} device={network.device} onConnect={onSelect} />}
        </Split>
      </Flex>
      {isSelected && (!network.settings || network.error) &&
        <div className="content">
          <WifiConnectionForm network={network} onCancel={onCancel} />
        </div>}
    </li>
  );
}

export default WifiNetworkListItem;
