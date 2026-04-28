import Cookies from 'js-cookie';

export const getBillingAttribution = () => ({
  visitor_id: Cookies.get('datafast_visitor_id'),
  session_id: Cookies.get('datafast_session_id'),
});
