import { useEffect, useState } from "react";
import QRCode from "qrcode";

type Props = {
  token: string;
  size?: number;
};

const TicketQr: React.FC<Props> = ({ token, size = 160 }) => {
  const [image, setImage] = useState("");

  useEffect(() => {
    let active = true;
    void QRCode.toDataURL(token, { width: size, margin: 2, errorCorrectionLevel: "H" }).then((value) => {
      if (active) setImage(value);
    });
    return () => {
      active = false;
    };
  }, [size, token]);

  return image ? <img src={image} width={size} height={size} alt="Admission ticket QR code" /> : <div className="rounded bg-white" style={{ width: size, height: size }} aria-label="Generating ticket QR code" />;
};

export default TicketQr;
