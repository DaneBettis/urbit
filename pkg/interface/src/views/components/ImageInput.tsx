import React, { useRef, useCallback, useState } from "react";

import {
  Box,
  StatelessTextInput as Input,
  Row,
  Button,
  Label,
  ErrorLabel,
  BaseInput
} from "@tlon/indigo-react";
import { useField } from "formik";
import { StorageState } from "~/types/storage-state";
import useStorage from "~/logic/lib/useStorage";

type ImageInputProps = Parameters<typeof Box>[0] & {
  id: string;
  label: string;
  storage: StorageState;
  placeholder?: string;
};

export function ImageInput(props: ImageInputProps) {
  const { id, label, storage, caption, placeholder, ...rest } = props;

  const { uploadDefault, canUpload, uploading } = useStorage(storage);

  const [field, meta, { setValue, setError }] = useField(id);

  const ref = useRef<HTMLInputElement | null>(null);

  const onImageUpload = useCallback(async () => {
    const file = ref.current?.files?.item(0);

    if (!file || !canUpload) {
      return;
    }
    try {
      const url = await uploadDefault(file);
      setValue(url);
    } catch (e) {
      setError(e.message);
    }
  }, [ref.current, uploadDefault, canUpload, setValue]);

  const onClick = useCallback(() => {
    ref.current?.click();
  }, [ref]);

  return (
    <Box display="flex" flexDirection="column" {...props}>
      <Label htmlFor={id}>{label}</Label>
      {caption ? (
        <Label mt="2" gray>
          {caption}
        </Label>
      ) : null}
      <Row mt="2" alignItems="flex-end">
        <Input
          type={"text"}
          hasError={meta.touched && meta.error !== undefined}
          placeholder={placeholder}
          {...field}
        />
        {canUpload && (
          <>
            <Button
              type="button"
              ml={1}
              border={1}
              borderColor="lightGray"
              onClick={onClick}
              flexShrink={0}
            >
              {uploading ? "Uploading" : "Upload"}
            </Button>
            <BaseInput
              style={{ display: "none" }}
              type="file"
              id="fileElement"
              ref={ref}
              accept="image/*"
              onChange={onImageUpload}
            />
          </>
        )}
      </Row>
      <ErrorLabel mt="2" hasError={!!(meta.touched && meta.error)}>
        {meta.error}
      </ErrorLabel>
    </Box>
  );
}
