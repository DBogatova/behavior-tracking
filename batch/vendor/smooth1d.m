function [vec_out] = smooth1d(vec_in,sig1)

idim = length(vec_in);
filtvec = exp(-1/2*(((([1:idim]-(idim/2+1)))/idim*sig1).^2));
if (size(filtvec,1) ~= size(vec_in,1))
  filtvec = filtvec.';
end
kvec = fftshift(fft(vec_in));
vec_out = ifft(ifftshift(kvec.*filtvec));