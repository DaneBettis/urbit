import React from 'react';

import {
  Col,
  Label,
  BaseLabel,
  BaseAnchor
} from '@tlon/indigo-react';
import { GroupNotificationsConfig } from '@urbit/api';
import { Association } from '@urbit/api/metadata';

import GlobalApi from '~/logic/api/global';
import { StatelessAsyncToggle } from '~/views/components/StatelessAsyncToggle';

export function GroupPersonalSettings(props: {
  api: GlobalApi;
  association: Association;
  notificationsGroupConfig: GroupNotificationsConfig;
}) {
  const groupPath = props.association.group;

  const watching = props.notificationsGroupConfig.findIndex(g => g === groupPath) !== -1;

  const onClick = async () => {
    const func = !watching ? 'listenGroup' : 'ignoreGroup';
    await props.api.hark[func](groupPath);
  };

  return (
    <Col px="4" pb="4" gapY="4">
      <BaseAnchor pt="4" fontWeight="600" id="notifications" fontSize="2">Group Notifications</BaseAnchor>
      <BaseLabel
        htmlFor="asyncToggle"
        display="flex"
        cursor="pointer"
      >
        <StatelessAsyncToggle selected={watching} onClick={onClick} />
        <Col>
          <Label>Notify me on group activity</Label>
          <Label mt="2" gray>Send me notifications when this group changes</Label>
        </Col>
      </BaseLabel>
    </Col>
  );
}
