import React, { ReactNode } from "react";
import { useLocation } from "react-router-dom";
import Helmet from "react-helmet";

import { Text, Box, Col, Row } from '@tlon/indigo-react';

import { NotificationPreferences } from "./components/lib/NotificationPref";
import DisplayForm from "./components/lib/DisplayForm";
import S3Form from "./components/lib/S3Form";
import { CalmPrefs } from "./components/lib/CalmPref";
import SecuritySettings from "./components/lib/Security";
import { LeapSettings } from "./components/lib/LeapSettings";
import { useHashLink } from "~/logic/lib/useHashLink";
import { SidebarItem as BaseSidebarItem } from "~/views/landscape/components/SidebarItem";
import { PropFunc } from "~/types";

export const Skeleton = (props: { children: ReactNode }) => (
  <Box height="100%" width="100%" px={[0, 3]} pb={[0, 3]} borderRadius={1}>
    <Box
      height="100%"
      width="100%"
      borderRadius={1}
      bg="white"
      border={1}
      borderColor="washedGray"
    >
      {props.children}
    </Box>
  </Box>
);

type ProvSideProps = "to" | "selected";
type BaseProps = PropFunc<typeof BaseSidebarItem>;
function SidebarItem(props: { hash: string } & Omit<BaseProps, ProvSideProps>) {
  const { hash, icon, text, ...rest } = props;

  const to = `/~settings#${hash}`;

  const location = useLocation();
  const selected = location.hash.slice(1) === hash;

  return (
    <BaseSidebarItem
      {...rest}
      icon={icon}
      text={text}
      to={to}
      selected={selected}
    />
  );
}

function SettingsItem(props: { children: ReactNode }) {
  const { children } = props;

  return (
    <Box borderBottom="1" borderBottomColor="washedGray">
      {children}
    </Box>
  );
}

export default function SettingsScreen(props: any) {

  const location = useLocation();
  const hash = location.hash.slice(1)

  return (
    <>
      <Helmet defer={false}>
        <title>Landscape - Settings</title>
      </Helmet>
      <Skeleton>
        <Row height="100%" overflow="hidden">
          <Col
            height="100%"
            borderRight="1"
            borderRightColor="washedGray"
            display={["none", "flex"]}
            minWidth="250px"
            maxWidth="350px"
          >
            <Text
              display="block"
              my="4"
              mx="3"
              fontSize="2"
              fontWeight="medium"
            >
              System Preferences
            </Text>
            <Col gapY="1">
              <SidebarItem
                icon="Inbox"
                text="Notifications"
                hash="notifications"
              />
              <SidebarItem icon="Image" text="Display" hash="display" />
              <SidebarItem icon="Upload" text="Remote Storage" hash="s3" />
              <SidebarItem icon="LeapArrow" text="Leap" hash="leap" />
              <SidebarItem icon="Node" text="CalmEngine" hash="calm" />
              <SidebarItem
                icon="Locked"
                text="Devices + Security"
                hash="security"
              />
            </Col>
          </Col>
          <Col flexGrow={1} overflowY="auto">
            <SettingsItem>
              {hash === "notifications" && (
                <NotificationPreferences
                  {...props}
                  graphConfig={props.notificationsGraphConfig}
                />
              )}
              {hash === "display" && (
                <DisplayForm s3={props.s3} api={props.api} />
              )}
              {hash === "s3" && (
                <S3Form s3={props.s3} api={props.api} />
              )}
              {hash === "leap" && (
                <LeapSettings api={props.api} />
              )}
              {hash === "calm" && (
                <CalmPrefs api={props.api} />
              )}
              {hash === "security" && (
                <SecuritySettings api={props.api} />
              )}
            </SettingsItem>
          </Col>
        </Row>
      </Skeleton>
    </>
  );
}
