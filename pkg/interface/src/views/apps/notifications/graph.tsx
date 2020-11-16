import React, { ReactNode, useCallback } from "react";
import moment from "moment";
import { Row, Box, Col, Text, Anchor, Icon, Action } from "@tlon/indigo-react";
import { Link, useHistory } from "react-router-dom";
import _ from "lodash";
import {
  Post,
  GraphNotifIndex,
  GraphNotificationContents,
  Associations,
  Content,
  Rolodex,
} from "~/types";
import { Header } from "./header";
import { cite, deSig, pluralize } from "~/logic/lib/util";
import { Sigil } from "~/logic/lib/sigil";
import RichText from "~/views/components/RichText";
import GlobalApi from "~/logic/api/global";
import ReactMarkdown from "react-markdown";
import { getSnippet } from "~/logic/lib/publish";
import styled from "styled-components";

function getGraphModuleIcon(module: string) {
  if (module === "link") {
    return "Links";
  }
  return _.capitalize(module);
}

const FilterBox = styled(Box)`
  background: linear-gradient(
    to bottom,
    transparent,
    ${(p) => p.theme.colors.white}
  );
`;

function describeNotification(description: string, plural: boolean) {
  switch (description) {
    case "link":
      return `added ${pluralize("new link", plural)} to`;
    case "comment":
      return `left ${pluralize("comment", plural)} on`;
    case "note":
      return `posted ${pluralize("note", plural)} to`;
    case "mention":
      return "mentioned you on";
    default:
      return description;
  }
}

const GraphUrl = ({ url, title }) => (
  <Box borderRadius="2" p="2" bg="scales.black05">
    <Anchor underline={false} target="_blank" color="black" href={url}>
      <Icon verticalAlign="bottom" mr="2" icon="ArrowExternal" />
      {title}
    </Anchor>
  </Box>
);

const GraphNodeContent = ({ contents, mod, description, index }) => {
  const idx = index.slice(1).split("/");
  if (mod === "link") {
    if (idx.length === 1) {
      const [{ text }, { url }] = contents;
      return <GraphUrl title={text} url={url} />;
    } else if (idx.length === 2) {
      const [{ text }] = contents;
      return <RichText>{text}</RichText>;
    }
    return null;
  }
  if (mod === "publish") {
    if (idx.length !== 3) {
      return null;
    } else if (idx[1] === "2") {
      const [{ text }] = contents;
      return <RichText>{text}</RichText>;
    } else if (idx[1] === "1") {
      const [{ text: header }, { text: body }] = contents;
      const snippet = getSnippet(body);
      return (
        <Col>
          <Box mb="2" fontWeight="500">
            <Text>{header}</Text>
          </Box>
          <Box overflow="hidden" maxHeight="400px">
            <Text lineHeight="tall">{snippet}</Text>
            <FilterBox
              width="100%"
              zIndex="1"
              height="calc(100% - 2em)"
              bottom="-4px"
              position="absolute"
            />
          </Box>
        </Col>
      );
    }
  }
  return null;
};

function getNodeUrl(mod: string, group: string, graph: string, index: string) {
  const graphUrl = `/~landscape${group}/resource/${mod}${graph}`;
  const idx = index.slice(1).split("/");
  if (mod === "publish") {
    const [noteId] = idx;
    return `${graphUrl}/note/${noteId}`;
  } else if (mod === "link") {
    const [linkId] = idx;
    return `${graphUrl}/-${linkId}`;
  }
  return "";
}
const GraphNode = ({
  contents,
  author,
  mod,
  description,
  time,
  index,
  graph,
  group,
  read,
  onRead
}) => {
  author = deSig(author);
  const history = useHistory();

  const img = (
    <Sigil
      ship={`~${author}`}
      size={16}
      icon
      color={`#000000`}
      classes="mix-blend-diff"
    />
  );

  const nodeUrl = getNodeUrl(mod, group, graph, index);

  const onClick = useCallback(() => {
    if(!read) {
      onRead();
    }
    history.push(nodeUrl);
  }, [read, onRead]);

  return (
    <Row onClick={onClick} gapX="2" pt="2">
      <Col>{img}</Col>
      <Col alignItems="flex-start">
        <Row
          mb="2"
          height="16px"
          alignItems="center"
          p="1"
          backgroundColor="white"
        >
          <Text mono title={author}>
            {cite(author)}
          </Text>
          <Text ml="2" gray>
            {moment(time).format("HH:mm")}
          </Text>
        </Row>
        <Row p="1">
          <GraphNodeContent
            contents={contents}
            mod={mod}
            description={description}
            index={index}
          />
        </Row>
      </Col>
    </Row>
  );
};

export function GraphNotification(props: {
  index: GraphNotifIndex;
  contents: GraphNotificationContents;
  archived: boolean;
  read: boolean;
  time: number;
  timebox: BigInteger;
  associations: Associations;
  contacts: Rolodex;
  api: GlobalApi;
}) {
  const { contents, index, read, time, api, timebox } = props;

  const authors = _.map(contents, "author");
  const { graph, group } = index;
  const icon = getGraphModuleIcon(index.module);
  const desc = describeNotification(index.description, contents.length !== 1);

  const onClick = useCallback(() => {
    if (props.archived) {
      return;
    }

    const func = read ? "unread" : "read";
    return api.hark[func](timebox, { graph: index });
  }, [api, timebox, index, read]);

  return (
    <Col p="2">
      <Header
        onClick={onClick}
        archived={props.archived}
        time={time}
        read={read}
        authors={authors}
        moduleIcon={icon}
        channel={graph}
        contacts={props.contacts}
        group={group}
        description={desc}
        associations={props.associations}
      />
      <Col pl="5">
        {_.map(contents, (content, idx) => (
          <GraphNode
            author={content.author}
            contents={content.contents}
            mod={index.module}
            time={content["time-sent"]}
            description={index.description}
            index={content.index}
            graph={graph}
            group={group}
            read={read}
            onRead={onClick}
          />
        ))}
      </Col>
    </Col>
  );
}
