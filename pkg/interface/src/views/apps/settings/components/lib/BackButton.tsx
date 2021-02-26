import React from 'react';
import { Link } from 'react-router-dom';
import { Text } from '@tlon/indigo-react';

export function BackButton(props: {}) {
  return (
    <Link to="/~settings">
      <Text fontSize="2" fontWeight="medium">{"<- Back to System Preferences"}</Text>
    </Link>
  );
}
